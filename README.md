# dbt-denodo-extras

Governance as code for [Denodo](https://www.denodo.com) with [dbt](https://www.getdbt.com): a set of macros that sits on top of Denodo's **official** dbt adapter, [`dbt-denodo`](https://pypi.org/project/dbt-denodo/) 1.0.0, published by Denodo Research Labs.

This is not an adapter and not a fork. You install the official adapter as usual; this repository adds two things next to it:

- a **compatibility layer** that makes the adapter behave the way a governed Denodo instance needs (objects modified in place, catalog, contracts, folders, descriptions), designed to be upstreamed into the adapter;
- **governance macros** that let each data product declare its Denodo tags, roles and privileges in its own dbt project, apply them on every build, and audit what was changed by hand.

The end-to-end example, a governed data mesh with three data products and four Global Security Policies, is in the companion repository `denodo-data-mesh-demo`.

## The model behind it: staging and gold

The examples below speak of `staging` and of a published layer. Both come from two well-known conventions, applied to Denodo.

**The medallion model** splits data into layers of increasing quality: *bronze* (raw, as delivered by the source), *silver* (cleaned, typed, renamed) and *gold* (business-ready, what consumers use).

**dbt's recommended project structure** says the same in its own words: a `models/staging/` folder with one model per source table that only casts and renames (no join, no business logic), and a `models/marts/` folder with the models that consumers query.

**On Denodo, a layer is a virtual database**, because that is where access is granted. So a data product is two databases:

| Layer | Medallion | dbt folder | Denodo database | Content | Who can read it |
|---|---|---|---|---|---|
| staging | bronze + silver | `models/staging/` | `sales_staging` | datasources (`ds_`), base views (`bv_`), one cast-and-rename view per table (`stg_`) | nobody but the product's developers, and only its metadata |
| gold | gold | `models/marts/` | `sales` | the published views only (`iv_`, `be_`, `agg_`) | consumers, with `EXECUTE` |

In other words: on Denodo, **staging = bronze + silver**, in one database suffixed `_staging`. The database **without** the suffix (`sales`) is the one that is exposed, and the only one: it is the *gold* layer of the medallion model, the *marts* of dbt.

A consumer never gets access to the staging database: the gold views read it through Denodo's indirect access. That one rule is what makes governance on the gold layer sufficient, since nobody can go around a masked column by reading the base view underneath. It is also why the macros below put the governance tags on the **gold** models only (`+post_hook` on `marts/`), and why one dbt project writes into two databases (`+database` per folder).

Bronze and silver share one database here because, on a virtualization layer, the bronze is not a copy: the base views *are* the source. If you prefer three databases, nothing in the macros depends on two.

## What is inside

| File | Content |
|---|---|
| `macros/denodo_custom_macros.sql` | Governance as code: roles and privileges (`denodo_apply_roles`), tags (`denodo_apply_tags`), drift audit (`denodo_audit`) |
| `macros/_adapter__denodo.sql` | Compatibility layer for `dbt-denodo` 1.0.0: seven overrides, each documented with its diagnosis and the test that validated it |
| `macros/_adapter__core.sql` | `generate_schema_name`: the schema follows the database (Denodo has no schemas) |

### 1. Roles and privileges: who may open which database

Which role may connect to which database, and do what in it, is a property of the data product. So it is declared in the product's `dbt_project.yml`:

```yaml
vars:
  denodo:
    security:
      sales_developer:
        description: "Developer of the Sales data product"
        privileges:
          sales_staging: [CONNECT, METADATA]   # sees the lineage, never the data
          sales:         [CONNECT, METADATA]
        granted_to: [denodo_developer_global]  # pre-existing umbrella role
      sales_rep:
        description: "Sales rep"
        privileges:
          sales: [CONNECT, EXECUTE]            # may query the published views
```

and applied at the start of every dbt command:

```yaml
on-run-start:
  - "{{ denodo_apply_roles() }}"
```

**What you get in Denodo.** After a `dbt build`, the roles exist on the server exactly as declared. This is `DESC VQL ROLE` on the demo server, where three products each grant `sales_rep` on their own database:

```sql
CREATE ROLE chinook_sales_developer 'Developer of the Sales data product'
GRANT CONNECT, METADATA ON chinook_sales
GRANT CONNECT, METADATA ON chinook_sales_staging;

CREATE ROLE sales_rep 'Sales rep'
GRANT CONNECT, EXECUTE ON chinook_analytics     -- granted by the analytics project
GRANT CONNECT, EXECUTE ON chinook_music         -- granted by the music project
GRANT CONNECT, EXECUTE ON chinook_sales;        -- granted by the sales project

CREATE ROLE denodo_developer_global 'Platform developers (umbrella role, outside dbt)'
GRANT ROLE chinook_music_developer,chinook_sales_developer,chinook_analytics_developer;
```

Concretely, the account `dev_global` (a member of the umbrella role) lists the six views of `chinook_sales_staging`, and gets *"The user does not have EXECUTE privileges on the view 'bv_customer'"* on any `SELECT`. "Developers see the lineage, never the data" is enforced by the server, not written in a wiki.

How it behaves:

- **It converges.** Declared privileges are granted; every other database-level privilege is revoked (`CONNECT`, `METADATA`, `EXECUTE`, `WRITE`, `INSERT`, `UPDATE`, `DELETE`, `FILE`, `CREATE` and the four `CREATE_*`; `ADMIN` is never touched). Measured: all of them, granted by hand, are gone after the next build.
- **It is scoped to the project's own databases.** The sales project never touches what the music project granted to the same role on `chinook_music`, so several products can admit the same role safely.
- **`granted_to` plugs the product into the organisation.** The umbrella role (`denodo_developer_global`) already exists and holds real people; it belongs to the security team, not to any product. The product only adds its own role into it, never removes a membership, and fails explicitly if the umbrella role does not exist.
- **People stay out of dbt.** Users, user-to-role assignments and administrator roles are deliberately not managed: they come from LDAP or Active Directory, and they outlive every data product.
- **Only declared roles are touched.** A role that is not in the YAML, or that was removed from it, keeps what it has: the audit below reports it.

### 2. Tags: which column is sensitive

A Denodo tag is a label on a view or a column. On its own it does nothing: a Global Security Policy, written once by the governance team, decides what a tag means (*"columns tagged `class_pii` are masked, except for customer support"*). The product only says which of its columns carry which tag, in the model YAML, next to the published contract:

```yaml
models:
  - name: iv_invoices
    config:
      contract:
        enforced: true
    columns:
      - name: email
        data_type: varchar
        config:
          tags: [class_pii]        # always under config:, a bare tags: is ignored on a model
```

applied after each published model is built:

```yaml
models:
  sales:
    marts:
      +post_hook: "{{ denodo_apply_tags() }}"
```

**What you get in Denodo.** The tag appears on the column (in Design Studio, or in `DESC VQL VIEW`: `email (...) TAGS (class_pii)`), and every policy written on `class_pii` now applies to that column, for every query, including queries on views of other databases that read it. Remove the line from the YAML and rebuild: the tag is detached, and the e-mails are back in clear for the analyst. Put it back: they are masked again. The YAML is the source of truth.

How it behaves: only the tags listed in `vars: denodo: governance_tags` are managed (dbt tags are also selectors; the whitelist keeps a tag like `nightly` out of Denodo). For each of them, one `ALTER TAG … ADD_TO (…) REMOVE_FROM (…)` makes the view converge on the YAML. The tags themselves and the policies are created in VQL by the governance team: dbt never creates or replaces a tag.

### 3. Audit: what was changed by hand

Nobody becomes a dbt shop on a Monday. People keep using Design Studio: they grant a privilege during an incident, build a quick view, tag a column. The audit shows it before the next build overwrites it, or before it becomes a security hole:

```
dbt run-operation denodo_audit
```

It **changes nothing**. Here is the real output on the demo server, after five changes made by hand in `chinook_sales` (a grant on one view to a role, the same grant directly to a user, a role, a view and a tag):

```
=======================================================================
Denodo AUDIT: VDBs governed by this project: chinook_sales, chinook_sales_staging
=======================================================================
Active rules on our tags (scope_customer, class_pii):
  . p_mask_email_pii  (class_pii)
  . p_salesrep_own_customers  (scope_customer)

  ROLE  analyst: VIEW-level privilege on chinook_sales.iv_invoices (EXECUTE): granted on one view, so it shows in no database-level declaration
  ROLE  role_added_by_hand: access to chinook_sales (CONNECT, EXECUTE) NOT declared in the YAML
  USER  analyst_bob: DIRECT privilege on chinook_sales.iv_invoices (EXECUTE): not through a role, so the policies written on roles do not restrict it
  VIEW  chinook_sales.hand_built_view: derived view that no dbt model produces (orphan?)
  TAG   class_pii on chinook_sales.iv_invoices.customer_name: NOT declared in the YAML
-----------------------------------------------------------------------
5 finding(s). Report only: nothing was modified.
```

How to read it:

- **`USER … DIRECT privilege`** is the one to look at first, because it is a real hole. Denodo attaches the restrictions of a policy to the audience that triggers it. When the audience is written in roles, a privilege granted directly to a user carries no restriction (documented in the Administration Guide, "Global Security Policies"). Measured on the demo: with this single grant, `analyst_bob` read the masked e-mails in clear; the same grant to a sales rep showed him every invoice. Access must go through roles.
- **`ROLE … VIEW-level privilege`**: a grant on a single view shows in no database-level declaration, so nobody reviewing the YAML sees it. Measured: granted to a role the policy already covers, it does not lift the masking, but it sits outside the access model the product declared.
- **`ROLE … NOT declared`**: a role reaches the product's data and nobody declared it. Legitimate or not, it must be either declared in the YAML or removed.
- **`VIEW … orphan`**: a view no model produces. Either a model was deleted (dbt never drops the old view) or someone built on the published layer by hand.
- **`TAG … NOT declared`**: a tag attached by hand. If the tag is whitelisted, the next build will detach it, and the masking it brought will disappear with it.

The audit also lists the policies that apply to the project's tags, and warns when one of them is disabled: a disabled policy is a rule that exists and protects nothing.

Why report only, and not fix: an access granted at 3 a.m. during an incident may be legitimate, and a build that silently revokes it is worse than the drift. The audit prints, a human decides. Why not a hook: Denodo exposes no catalog view for privileges, so the audit reads them role by role (`LIST ROLES` plus one `DESC VQL ROLE` each). That is fine nightly or in CI, and too slow for every `dbt run`.

### 4. Compatibility layer for the official adapter

| # | Override | What it changes |
|---|---|---|
| 1 | `view` materialization | Issues a `CREATE OR REPLACE VIEW`, as Design Studio does, instead of building a temporary view, dropping the target and renaming. The object keeps its identity, so its tags, view-level privileges, dependent views (in any database) and interface implementations are preserved across builds. Model contracts (`contract: enforced: true`) are checked. |
| 2 | `denodo__get_catalog` | `dbt docs generate` returns every view of the target databases, with columns, types and column descriptions. |
| 3 | `denodo__get_empty_schema_sql` | Contracts on `decimal` columns work without an unactionable precision warning (Denodo rejects `cast(NULL as decimal(p,s))`). |
| 4 | `denodo__create_folder` | `folder: '/a/b/c'` creates the parent folders first. |
| 5 | `persist_docs` | `description:` of models and columns is written into Denodo (`ALTER VIEW … DESCRIPTION`) on every build, where the Data Catalog, BI tools and the Denodo MCP Server read it. |
| 6 | drop, rename, `create_table_as` | A database whose name has capitals (`Sales_Gold`) works. The adapter writes the name unquoted (`CONNECT DATABASE Sales_Gold`), the PostgreSQL interface folds it to lower case, and the database is not found. Overrides 4 and 5 quote it too. |
| 7 | `table` materialization | Caches the view in place, as Design Studio and the Scheduler do, instead of a temporary view, two renames and a `DROP … CASCADE`. Views built on top of a `table` model now survive its rebuild, the reload is atomic, the cache table gets a fixed name, and `cache_preload=false` leaves the load to the Scheduler. See below. |

#### The `table` materialization: a cache, reloaded in place

On Denodo, `materialized='table'` means a view with a full cache. One build issues:

```sql
CREATE OR REPLACE VIEW "sales"."agg_sales_by_label" AS SELECT …;
ALTER VIEW "agg_sales_by_label" CACHE FULL NO_STATUS … CACHE_TABLE_NAME 'agg_sales_by_label';
SELECT * FROM "sales"."agg_sales_by_label"
  CONTEXT ('cache_preload'='true', 'cache_invalidate'='all_rows', 'cache_wait_for_load'='true', 'cache_return_query_results'='false');
```

- **The object is kept.** As with `view` (override 1), the views built on it, in any database, keep working; so do its tags and view-level privileges. The adapter's own version renamed and dropped it with `CASCADE` on every build, taking the views built on it along, and left `<x>__dbt_tmp` behind when the load failed.
- **The reload is atomic.** Without control columns (`NO_STATUS`, the default), `'cache_invalidate'='all_rows'` loads a new cache table and switches to it at the end: a query running during the load reads the previous data, and a load that fails leaves the previous data in place (measured).
- **The cache table has a known name**, the view's name ("Custom table name", Denodo 9.3+), or `config(cache_table_name='…')`. Denodo adds a numeric suffix when the name is already taken, for instance by a table left by the adapter's renames: `GET_CACHE_TABLE()` returns the real name.
- **`config(cache_preload=false)`** defines the view and its cache without loading it. Use it when a Scheduler job loads the cache (with retries, when the source is unreliable), or when the load is too long for a build. The data cached before the build is still served after it; a new model returns no row until its first load.

```sql
{{ config(materialized='table', cache_preload=false) }}
```

Not covered: remote tables (`remote=true`), `incremental` and `materialized_view` keep the adapter's behaviour.

Each override is self-contained and can move as-is into the adapter's `dbt/include/denodo/macros/`. Once the adapter ships the equivalent, delete the override.

`generate_schema_name` is different: dbt only reads it from the root project, so no adapter can ship it. It stays in your project (here, through `macro-paths`).

## Installation

There is nothing to install. You need a working dbt project on Denodo's official adapter; then clone this repository next to it:

```bash
git clone https://github.com/vharcq/dbt-denodo-extras.git
```

```
workspace/
  dbt-denodo-extras/        <- this repository
  my_dbt_project/
    dbt_project.yml
```

and add one line to `dbt_project.yml`:

```yaml
macro-paths: ["macros", "../dbt-denodo-extras/macros"]
```

`macro-paths` is the list of folders where dbt looks for macros, relative to `dbt_project.yml`. Its default is `["macros"]`; adding `../dbt-denodo-extras/macros` makes these files part of your project, exactly as if you had copied them into your own `macros/` folder (which works too). To update, `git pull` in `dbt-denodo-extras`.

Why not a dbt package (`packages.yml`)? Because dbt silently ignores a materialization and a `generate_schema_name` that come from a package: the build stays green and the adapter's own behaviour applies. Macros reached through `macro-paths` belong to your project, so they take precedence.

## Configuration

A complete `dbt_project.yml` for one data product, two databases:

```yaml
name: sales
profile: denodo
macro-paths: ["macros", "../dbt-denodo-extras/macros"]

vars:
  denodo:
    governance_tags: [class_pii, scope_customer]
    security:
      sales_rep:
        privileges:
          sales: [CONNECT, EXECUTE]

on-run-start:
  - "{{ denodo_apply_roles() }}"

models:
  sales:
    +materialized: view
    +database: sales
    +persist_docs:
      relation: true
      columns: true
    staging:
      +database: sales_staging
    marts:
      +post_hook: "{{ denodo_apply_tags() }}"
```

Deployment order matters once roles come from dbt: anything that names a role (a user-to-role assignment, the `AUDIENCE` of a Global Security Policy) must be applied after the first `dbt build`. The demo repository shows the full sequence.

## Good to know

- The role hook runs at the start of `dbt run`, `build`, `test` and the other commands that trigger `on-run-start`, and it creates roles and grants privileges: the account dbt connects with must be allowed to do that. The audit reads `DESC VQL ROLE` and `DESC VQL USER`, which only an administrator can run on other accounts. The demo connects as an administrator.
- A `materialized='table'` model is a Denodo cache: building it reads the sources, unless `cache_preload=false`. It is modified in place (override 7), not dropped and recreated.
- A source that fails now and then fails the build of the `table` model that loads it, and the previous cached data stays. `dbt retry` re-runs only what failed; or leave the load to the Scheduler with `cache_preload=false`.
- `CREATE OR REPLACE` keeps an object's identity but replaces its definition: a description or a cache set by hand on a dbt-managed view is replaced on the next build. Declare them in dbt (`description:` with `persist_docs`, `materialized='table'`).
- dbt never drops a view whose model was deleted: `denodo_audit` lists it.
- `persist_docs` fails on a model whose top level is a `UNION` ("The field properties can only be specified for derived fields"): Denodo accepts no column description on a union view. Wrap it: `select a, b from ( … union all … ) u`.
- Database names with capitals work everywhere the macros name a database (`CONNECT DATABASE`, `ALTER TAG`, `ALTER ROLE … ON`): they are always quoted.

## Compatibility

| Component | Tested version |
|---|---|
| Denodo Virtual DataPort | 9.4.7 |
| dbt-core | 1.12.6 |
| dbt-denodo (official adapter) | 1.0.0 |
| Connection | PostgreSQL-compatible interface, port 9996 |

## License

[Apache License 2.0](LICENSE). Two macros of the compatibility layer are modified versions of macros of the official `dbt-denodo` adapter, itself under the Apache License 2.0: see [NOTICE](NOTICE). The adapter and the Denodo JDBC driver are not redistributed here.
