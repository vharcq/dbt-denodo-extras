{#
  ============================================================================
   dbt-denodo — COMPATIBILITY LAYER
  ============================================================================

  Seven overrides for the official `dbt-denodo 1.0.0` adapter, grouped in one file so
  they can be upstreamed. They contain NOTHING project-specific: they can move as-is
  into the adapter (`dbt/include/denodo/macros/`), after which this file is no longer
  needed.

  Tested on: Denodo Virtual DataPort 9.4.7, dbt-core 1.12.6, dbt-denodo 1.0.0.

  Origin: overrides 2 (`denodo__get_catalog`), 4 (`denodo__create_folder`) and 6
  (drop, rename, create_table_as) are modified versions of the macros of the same
  name in dbt-denodo 1.0.0,
  Copyright (c) 2026 denodo technologies, Apache License 2.0. The comment above each
  one says what was changed. The other overrides are original. See NOTICE.

   1. `view` materialization          — replace the view in place, keep the object
   2. `denodo__get_catalog`           — a complete catalog for `dbt docs generate`
   3. `denodo__get_empty_schema_sql`  — contracts on decimal columns, without warning
   4. `denodo__create_folder`         — `folder='/a/b/c'` creates `/a` and `/a/b` too
   5. `persist_docs`                  — YAML descriptions written into Denodo
   6. drop / rename / `table`         — database names with upper case letters
   7. `table` materialization         — cache the view in place, reload atomically

  Packaging note: a materialization defined in a dbt **package** is silently ignored;
  shipped in the **adapter**, it applies correctly. On the project side it must live in
  the root project's `macros/` (or in a folder mounted through `macro-paths`, as here).
#}


{#
  ---------------------------------------------------------------------------
   1. `view` MATERIALIZATION — replace the view in place
  ---------------------------------------------------------------------------
  The adapter defines no `view` materialization of its own, so dbt-core's default one
  applies: build `<x>__dbt_tmp`, then swap it in with renames and a drop. That swap
  goes through the adapter's `rename_relation` and `drop_relation`, which both issue
  `DROP VIEW … CASCADE`. The net effect on every build:

      CREATE OR REPLACE VIEW <x>__dbt_tmp AS … ;
      DROP VIEW <x> CASCADE;                     <-- the original object is dropped
      ALTER VIEW <x>__dbt_tmp RENAME <x>;

  That is the right pattern on a warehouse. In Denodo, an object carries an internal
  id, and what is attached to it goes with the drop:
    - the **tags** on the view and its columns, which the Global Security Policies
      rely on (a policy with no tagged element left applies to nothing);
    - **view-level privileges** (`GRANT EXECUTE ON <vdb>.<view>`);
    - **every view depending on it**, including in another VDB and another dbt project
      (measured: a consumer's VDB left with 0 views while dbt printed
      `Completed successfully`);
    - the implementation binding of an interface view pointing at it.

  Design Studio, by contrast, issues a `CREATE OR REPLACE`: the object is modified, not
  replaced. The adapter's own `denodo__create_view_as` macro already emits exactly that
  VQL — it just has to be called on the target, with no temp view and no DROP.

  Verified after the switch: a consumer view in another VDB stays intact, a view-level
  privilege survives, tags survive, an interface view stays implemented.
#}
{% materialization view, adapter='denodo' -%}
    {{ return(denodo_view_replace(this, sql, pre_hooks, post_hooks)) }}
{%- endmaterialization %}


{% macro denodo_view_replace(target, sql, pre_hooks, post_hooks) -%}

    {%- set target_relation = target.incorporate(type='view') -%}

    {{ run_hooks(pre_hooks, inside_transaction=False) }}
    {{ run_hooks(pre_hooks, inside_transaction=True) }}

    {#- Model contracts: the MATERIALIZATION is what triggers the check. dbt's own
        version calls get_assert_columns_equivalent(), so a custom one must do the same
        — otherwise `contract: enforced: true` is accepted but verifies NOTHING
        (measured: a green build with a published column missing). -#}
    {%- set contract_config = config.get('contract') -%}
    {%- if contract_config and contract_config.enforced -%}
        {{ get_assert_columns_equivalent(sql) }}
    {%- endif -%}

    {% call statement('main') -%}
        {{ denodo__create_view_as(target_relation, sql) }}
    {%- endcall %}

    {#- Descriptions BEFORE the post-hooks: CREATE OR REPLACE has just wiped them
        (see 5.), and the hooks (tags, grants) must see the final object. -#}
    {% do persist_docs(target_relation, model) %}

    {{ run_hooks(post_hooks, inside_transaction=True) }}
    {% do adapter.commit() %}
    {{ run_hooks(post_hooks, inside_transaction=False) }}

    {{ return({'relations': [target_relation]}) }}

{%- endmacro %}


{#
  ---------------------------------------------------------------------------
   2. `denodo__get_catalog` — the catalog was always empty
  ---------------------------------------------------------------------------
  The adapter's version reads `GET_ELEMENTS()` and filters on
  `lower(input_database_name) IN (…)`. `input_database_name` is an INPUT parameter of
  the procedure: a plain `WHERE input_database_name = 'x'` is bound as that parameter
  (measured: it returns the database's views). Wrapped in `lower()` and an `IN` list,
  the predicate is no longer bound: it is evaluated on the procedure's OUTPUT, where
  `input_database_name` is NULL, so it is never true. The same column is also selected
  as `table_schema` (NULL), and the query returns no column rows at all. The result:
  `dbt docs generate` writes an empty `catalog.json` — 0 nodes, 0 sources, no columns
  or types. Measured on 9.4.7: with the plain equality the procedure returns the 3
  views of a database, with `lower(…) IN (…)` it returns 0 rows.

  Fix: read `GET_VIEW_COLUMNS()` (one row per column) joined to `GET_VIEWS()`, and
  filter on `database_name`, a real OUTPUT column. `GET_VIEWS().view_type` is an
  INTEGER (0 = base view), hence the `CASE … = 0`. Measured: 0/0 -> 5 nodes / 4 sources
  on a two-VDB project, with columns, types and column descriptions.
#}
{% macro denodo__get_catalog(information_schema, schemas) %}

    {% set normalized_schemas = [] %}
    {% for schema in schemas %}
        {% do normalized_schemas.append(schema | lower) %}
    {% endfor %}

    {% call statement('catalog', fetch_result=True) %}
        SELECT
            c.database_name                                  AS "table_database",
            c.database_name                                  AS "table_schema",
            c.view_name                                      AS "table_name",
            CASE WHEN v.view_type = 0 THEN 'table' ELSE 'view' END AS "table_type",
            CAST(NULL AS text)                               AS "table_comment",
            CAST(NULL AS text)                               AS "table_owner",
            c.column_name                                    AS "column_name",
            c.ordinal_position                               AS "column_index",
            c.column_vdp_type                                AS "column_type",
            c.column_remarks                                 AS "column_comment"
        FROM GET_VIEW_COLUMNS() c
            LEFT JOIN GET_VIEWS() v
                ON  v.database_name = c.database_name
                AND v.name          = c.view_name
        {% if normalized_schemas | length > 0 %}
        WHERE lower(c.database_name) IN (
            {%- for schema in normalized_schemas -%}
                '{{ schema }}'{% if not loop.last %}, {% endif %}
            {%- endfor -%}
        )
        {% endif %}
    {% endcall %}

    {{ return(load_result('catalog').table) }}

{% endmacro %}


{#
  ---------------------------------------------------------------------------
   3. `denodo__get_empty_schema_sql` — unactionable precision warning
  ---------------------------------------------------------------------------
  Contract enforcement builds `select cast(null as <data_type>) as col, …`. Denodo
  rejects a NULL cast to a **parameterized** decimal:

      cast(NULL as decimal)          -> OK
      cast(1.5  as decimal(10,2))    -> OK
      cast(NULL as decimal(10,2))    -> Invalid function
                                        cast('decimal', NULL, 'DECIMAL(10,2)')

  A contract must therefore declare a bare `data_type: decimal`, which in turn always
  triggers dbt's "Detected columns with numeric type and unspecified precision/scale"
  warning. That warning is **unactionable** here: specifying the precision breaks the
  build.

  Fix: same body as `default__get_empty_schema_sql` minus that warn, keeping the error
  raised when a `data_type` is missing. Drop this override if the adapter ever accepts
  `cast(NULL as decimal(p,s))` — that would be the real fix.
#}
{% macro denodo__get_empty_schema_sql(columns) %}
    {%- set col_err = [] -%}
    select
    {% for i in columns %}
      {%- set col = columns[i] -%}
      {%- if col['data_type'] is not defined -%}
        {%- do col_err.append(col['name']) -%}
      {%- endif -%}
      {% set col_name = adapter.quote(col['name']) if col.get('quote') else col['name'] %}
      {{ cast('null', col['data_type']) }} as {{ col_name }}{{ ", " if not loop.last }}
    {%- endfor -%}
    {%- if (col_err | length) > 0 -%}
      {{ exceptions.column_type_missing(column_names=col_err) }}
    {%- endif -%}
{% endmacro %}


{#
  ---------------------------------------------------------------------------
   4. `denodo__create_folder` — create the parents too
  ---------------------------------------------------------------------------
  The adapter runs a single `CREATE OR REPLACE FOLDER '/a/b/c'`, and VDP refuses it
  when `/a/b` does not exist yet:

      Cannot create folder /a/b/c:  parent not found

  so `config(folder=...)` only worked one level deep, or onto folders created by hand.

  Fix: create every level, top-down (`/a`, `/a/b`, `/a/b/c`). Safe on existing
  folders: measured, `CREATE OR REPLACE FOLDER '/a'` keeps what `/a` contains (views
  and sub-folders), whereas plain `CREATE FOLDER` fails with `already exists`.
#}
{% macro denodo__create_folder(folder_path, database) -%}
    {%- if folder_path -%}
        {% if not folder_path.startswith('/') or folder_path.endswith('/') %}
            {% do exceptions.raise_compiler_error("Cannot create folder: Folder should start with the character '/' and should not end with it") %}
        {% endif %}
        {%- set database_name = database if database else (target.database) -%}
        {%- set parts = folder_path.strip('/').split('/') -%}
        {%- call statement('create_folder') -%}
            CONNECT DATABASE "{{ database_name }}";
            {%- for i in range(parts | length) %}
            CREATE OR REPLACE FOLDER '/{{ parts[:i + 1] | join('/') }}'{{ ";" if not loop.last }}
            {%- endfor %}
        {%- endcall -%}
    {%- endif -%}
{%- endmacro %}


{#
  ---------------------------------------------------------------------------
   5. `persist_docs` — the YAML descriptions never reached Denodo
  ---------------------------------------------------------------------------
  dbt's standard `persist_docs: {relation: true, columns: true}` config writes the
  model's and columns' `description:` into the database. The adapter implements
  neither `alter_relation_comment` nor `alter_column_comment`, and only its `table`
  materialization calls `persist_docs` — so a `view` model's descriptions stay in
  dbt's own docs site and never reach VDP, its Data Catalog, BI tools, or the
  Denodo MCP Server that serves view and column descriptions to AI agents.

  It matters twice: a `CREATE OR REPLACE` WIPES the descriptions (measured: view and
  column descriptions set by hand -> NULL after one `dbt run`), so anything not
  re-applied by the build is lost on every run.

  Fix: implement both macros with the VQL Design Studio itself issues —
      ALTER VIEW v DESCRIPTION = '…';
      ALTER VIEW v ( ALTER COLUMN c ADD ( DESCRIPTION = '…' ) );
  `ALTER VIEW` rejects a database-qualified name (`Syntax error … near '.'`), hence
  the `CONNECT DATABASE` first, as in `denodo__create_folder`. Converges for free: the
  rebuild has just wiped everything, so only YAML-described columns get a value.
#}
{% macro denodo_vql_literal(text) -%}
    '{{ (text | string)[:4000] | replace("'", "''") }}'
{%- endmacro %}


{% macro denodo__alter_relation_comment(relation, comment) -%}
    CONNECT DATABASE "{{ relation.database }}";
    ALTER VIEW "{{ relation.identifier }}" DESCRIPTION = {{ denodo_vql_literal(comment) }}
{%- endmacro %}


{% macro denodo__alter_column_comment(relation, column_dict) -%}
    {%- set described = [] -%}
    {%- for name, col in column_dict.items() if col.get('description') -%}
        {%- do described.append(col) -%}
    {%- endfor -%}
    {%- if described -%}
    CONNECT DATABASE "{{ relation.database }}";
    ALTER VIEW "{{ relation.identifier }}" (
        {%- for col in described %}
        ALTER COLUMN "{{ col['name'] }}" ADD ( DESCRIPTION = {{ denodo_vql_literal(col['description']) }} )
        {%- endfor %}
    )
    {%- else -%}
    SELECT 1
    {%- endif -%}
{%- endmacro %}


{#
  ---------------------------------------------------------------------------
   6. drop / rename / `table` — database names with upper case letters
  ---------------------------------------------------------------------------
  The adapter writes the database name UNQUOTED in its VQL (`CONNECT DATABASE x`,
  `DROP VIEW x."v"`). Over the PostgreSQL interface an unquoted identifier is folded
  to lower case, so a database whose name has capitals is not found:

      CONNECT DATABASE Sales_Gold     -> Error loading database 'sales_gold'
      CONNECT DATABASE "Sales_Gold"   -> OK

  Measured on 9.4.7: every model of such a database fails on its first statement. The
  demo databases are all lower case, so it never showed there. Overrides 4 and 5 quote
  the name too.

  Fix: the adapter's macros, unchanged except for the quotes around the database
  name. They cover the `view` materialization's drops and the whole `table` one
  (create, cache, rename, drop). A root-project macro takes precedence over the
  adapter's one even where the adapter calls it by its bare name. Not covered: remote
  tables (`remote=true`), `incremental`, `materialized_view`.
#}
{% macro denodo__drop_view(relation) -%}
    {% call statement('drop_view', auto_begin=False) -%}
         CONNECT DATABASE "{{ relation.database }}";
         DROP VIEW IF EXISTS "{{ relation.database }}"."{{ relation.identifier }}"  CASCADE;
    {%- endcall %}
{% endmacro %}


{% macro denodo__drop_table(relation) -%}
    {% call statement('drop_table', auto_begin=False) -%}
        DROP TABLE IF EXISTS "{{ relation.database }}"."{{ relation.identifier }}"  CASCADE
    {%- endcall %}
{% endmacro %}


{% macro denodo__rename_relation(from_relation, to_relation) -%}
    {% set drop_query %}
        DROP VIEW IF EXISTS "{{ to_relation.database }}"."{{ to_relation.identifier }}" CASCADE
    {% endset %}
    {% do run_query(drop_query) %}

    {% call statement('rename_relation') -%}
        CONNECT DATABASE "{{ from_relation.database }}";
        ALTER VIEW "{{ from_relation.identifier }}"
        RENAME "{{ to_relation.identifier }}";
    {%- endcall %}

    {% set relation_type = from_relation.type if from_relation is not none and from_relation.type is not none else to_relation.type %}
    {% set relation_type_normalized = relation_type | string | lower if relation_type is not none else '' %}
    {% set materialized_config = config.get('materialized') if config is defined else none %}
    {% if materialized_config == 'table' or relation_type_normalized == 'table' %}
        {% call statement('update_cache_table_name') -%}
            ALTER VIEW "{{ to_relation.identifier }}"
            CACHE FULL NO_STATUS
            BATCHSIZEINCACHE DEFAULT
            TIMETOLIVEINCACHE NOEXPIRE
            CACHE_TABLE_NAME '{{ to_relation.identifier }}'
        {%- endcall %}
    {% endif %}
{% endmacro %}


{% macro denodo__create_table_as(temporary, relation, sql) -%}
    {% if config.get('remote') | string | lower == 'true' %}
        {% do exceptions.raise_compiler_error("remote=true is not covered by the override of denodo__create_table_as in dbt-denodo-extras") %}
    {% endif %}

    {%- call statement('create_view') -%}
        CREATE OR REPLACE VIEW {{ relation }}
        {% if config.get('folder') -%}
            FOLDER = '{{ config.get('folder') }}'
        {%- endif %}
        AS
        {{ sql }}
    {%- endcall -%}

    {%- call statement('setup_cache') -%}
        CONNECT DATABASE "{{ relation.database }}";

        ALTER VIEW "{{ relation.identifier }}"
        CACHE FULL NO_STATUS
        BATCHSIZEINCACHE DEFAULT
        TIMETOLIVEINCACHE NOEXPIRE
        CACHE_TABLE_NAME '{{ relation.identifier }}'
    {%- endcall -%}

    {%- call statement('load_cache') -%}
        SELECT * FROM {{ relation }}
        CONTEXT (
        'i18n'='us_pst',
        'cache_preload'='true',
        'cache_wait_for_load'='true'
        )
    {%- endcall -%}

    {{ return('SELECT * FROM ' ~ relation) }}
{%- endmacro %}


{#
  ---------------------------------------------------------------------------
   7. `table` MATERIALIZATION — cache the view in place, reload atomically
  ---------------------------------------------------------------------------
  The adapter's `table` materialization builds `<x>__dbt_tmp`, gives it
  `CACHE FULL … CACHE_TABLE_NAME '<x>__dbt_tmp'`, preloads it, renames the current
  view to `<x>__dbt_backup`, renames the temp view to `<x>`, sets its
  `CACHE_TABLE_NAME` to `'<x>'` and drops the backup with `CASCADE`. Three problems:
    - the views built on top of a `table` model are dropped on every build (the
      CASCADE), and its tags and view-level privileges go with the object (see 1.);
    - the cache engine names its physical tables itself (measured: `GET_CACHE_TABLE`
      returns `<x>_<number>` after a build that asked for `'<x>'`), so the renames
      fight it;
    - the preload of `<x>__dbt_tmp` fails now and then with "Error executing data
      movement from view <x>__dbt_tmp to source vdpcachedatasource", and a failed build
      leaves `<x>__dbt_tmp` behind.

  Fix: what Design Studio and the Scheduler do. Replace the view in place, as in 1.,
  enable the full cache, and reload it with `'cache_invalidate' = 'all_rows'`. Without
  control columns (`NO_STATUS`, the default) the cache engine then loads a new cache
  table and switches to it at the end: the replacement is atomic, a query running
  during the load reads the previous data (Administration Guide, "Full Mode"). No temp
  view, no rename, no drop.

  The cache table gets a fixed name ("Custom table name", 9.3+): the view's name, or
  `config(cache_table_name='…')`. Denodo adds a numeric suffix when the name is already
  taken, which is how the adapter's renames ended up with `<x>_<number>`;
  `GET_CACHE_TABLE()` returns the real name.

  `config(cache_preload=false)` skips the reload: the build only defines the view and
  its cache, and the data is loaded elsewhere, typically by a Scheduler job with
  retries when the source is unreliable. The cached data survives the rebuild
  (measured: the previous rows are still served after `CREATE OR REPLACE` + `ALTER VIEW
  … CACHE FULL`), but a NEW model returns no row until its first load.

  `CREATE OR REPLACE` turns the cache off (cache_status 3 -> 0), hence the `ALTER VIEW
  … CACHE FULL` on every build; between the two statements, a query reads the source.
  Not covered: remote tables (`remote=true`).
#}
{% materialization table, adapter='denodo' -%}
    {{ return(denodo_table_replace(this, sql, pre_hooks, post_hooks)) }}
{%- endmaterialization %}


{% macro denodo_table_replace(target, sql, pre_hooks, post_hooks) -%}

    {%- set target_relation = target.incorporate(type='table') -%}

    {% if config.get('remote') | string | lower == 'true' %}
        {% do exceptions.raise_compiler_error("remote=true is not covered by the `table` materialization of dbt-denodo-extras") %}
    {% endif %}

    {{ run_hooks(pre_hooks, inside_transaction=False) }}
    {{ run_hooks(pre_hooks, inside_transaction=True) }}

    {%- set contract_config = config.get('contract') -%}
    {%- if contract_config and contract_config.enforced -%}
        {{ get_assert_columns_equivalent(sql) }}
    {%- endif -%}

    {% call statement('main') -%}
        {{ denodo__create_view_as(target_relation, sql) }}
    {%- endcall %}

    {% call statement('enable_cache') -%}
        CONNECT DATABASE "{{ target_relation.database }}";
        ALTER VIEW "{{ target_relation.identifier }}"
        CACHE FULL NO_STATUS
        BATCHSIZEINCACHE DEFAULT
        TIMETOLIVEINCACHE NOEXPIRE
        CACHE_TABLE_NAME '{{ config.get('cache_table_name', target_relation.identifier) }}'
    {%- endcall %}

    {% if config.get('cache_preload', true) %}
    {% call statement('load_cache') -%}
        SELECT * FROM {{ target_relation }}
        CONTEXT (
            'cache_preload' = 'true',
            'cache_invalidate' = 'all_rows',
            'cache_wait_for_load' = 'true',
            'cache_return_query_results' = 'false'
        )
    {%- endcall %}
    {% endif %}

    {% do persist_docs(target_relation, model) %}

    {{ run_hooks(post_hooks, inside_transaction=True) }}
    {% do adapter.commit() %}
    {{ run_hooks(post_hooks, inside_transaction=False) }}

    {{ return({'relations': [target_relation]}) }}

{%- endmacro %}
