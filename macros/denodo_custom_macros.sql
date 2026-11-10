{#
  ============================================================================
   GOVERNANCE AS CODE (roles, tags, audit)
  ============================================================================
   Three macros, driven by each project's `vars: denodo:` and model YAML:

     denodo_apply_roles   roles and their privileges per database (on-run-start)
     denodo_apply_tags    Denodo tags on the published views and columns (post-hook)
     denodo_audit         what was changed by hand (run-operation, report only)

   The names used in the comments below are examples only.

   See also, in this folder:
     - _adapter__denodo.sql    compatibility layer for the dbt-denodo adapter
     - _adapter__core.sql      override of a dbt-core macro
#}


{#
  ---------------------------------------------------------------------------
   denodo_apply_tags — governance declared in YAML, not in SQL
  ---------------------------------------------------------------------------
  Wired once per project as a folder-level hook:

      models:
        <project>:
          marts:
            +post_hook: "{{ denodo_apply_tags() }}"

  so no model .sql mentions governance, and a new gold model cannot silently miss it.
  Tags are then declared where the contract already lives — always under `config:`,
  on the view as well as on its columns:

      - name: iv_sales
        config:
          tags: [class_confidential]        # whole view
        columns:
          - name: email
            config:
              tags: [class_pii]             # single column

  A bare `tags:` works on a COLUMN but is SILENTLY IGNORED on a model (node.tags stays
  empty, no warning) — measured: a DENY policy anchored on that tag went inert. Hence the
  single rule: always `config: tags:`.

  WHITELIST (`vars: denodo: governance_tags`) — it does two jobs:

   1. FILTER. dbt `tags` are primarily selectors (`dbt run --select tag:nightly`), and
      `model.tags` also inherits folder-level `+tags` from dbt_project.yml. Without a
      whitelist, a scheduling tag would end up in an `ALTER TAG nightly` that fails
      because no such tag exists in Denodo.

   2. CONVERGENCE. For every whitelisted tag, this macro emits exactly one statement
      carrying BOTH clauses: `ADD_TO` for what the YAML declares, `REMOVE_FROM` for the
      rest of this view and its columns. So removing a tag from the YAML actually
      DETACHES it — the YAML is the source of truth, not just a nicer place to write it.
      `ALTER TAG … ADD_TO` alone is purely additive and would silently drift.

  Scope is per-view: a run only ever adds to / removes from THIS view and ITS columns,
  never another product's — two projects can therefore govern the same tag safely.

  Requirements: the tags must already exist (`ALTER TAG` on an unknown tag fails) —
  they are declared once, in VQL, by the governance team; dbt never creates one. Only
  the columns declared in the YAML are considered: with an enforced contract, that is
  every column of the view.
  Verified on VDP 9.4.7: an empty `ADD_TO`, and a `REMOVE_FROM` naming a view or column
  that does not carry the tag, are both accepted as no-ops.
#}
{% macro denodo_apply_tags() -%}
    {%- set governed = (var('denodo', {}).get('governance_tags') or []) -%}
    {%- if governed | length == 0 -%}
        SELECT 1
    {%- else -%}
        {%- set view = this.database ~ '.' ~ this.identifier -%}
        {%- set statements = [] -%}
        {%- for tag in governed -%}
            {%- set add_views, rm_views = [], [] -%}
            {%- set add_cols,  rm_cols  = [], [] -%}
            {%- if tag in (model.tags or []) -%}
                {%- do add_views.append(view) -%}
            {%- else -%}
                {%- do rm_views.append(view) -%}
            {%- endif -%}
            {%- for col_name, col in (model.columns or {}).items() -%}
                {%- if tag in (col.get('tags') or []) -%}
                    {%- do add_cols.append(view ~ '.' ~ col_name) -%}
                {%- else -%}
                    {%- do rm_cols.append(view ~ '.' ~ col_name) -%}
                {%- endif -%}
            {%- endfor -%}
            {%- do statements.append(
                    'ALTER TAG ' ~ tag
                    ~ ' ADD_TO (VIEWS (' ~ add_views | join(', ') ~ ') COLUMNS (' ~ add_cols | join(', ') ~ '))'
                    ~ ' REMOVE_FROM (VIEWS (' ~ rm_views | join(', ') ~ ') COLUMNS (' ~ rm_cols | join(', ') ~ '))'
                ) -%}
        {%- endfor -%}
        {{ statements | join(';
') }}
    {%- endif -%}
{%- endmacro %}


{#
  ---------------------------------------------------------------------------
   denodo_apply_roles — VDB <-> ROLE declared in YAML
  ---------------------------------------------------------------------------
  Wired once per project as a project-level hook:

      on-run-start:
        - "{{ denodo_apply_roles() }}"

  Declaration lives in `vars: denodo: security:` — role-centric, because a role spans
  BOTH VDBs of the data product and carries its own memberships:

      security:
        sales_developer:
          description: "Developer of the Sales data product"
          privileges:
            sales_staging: [CONNECT, METADATA]   # lineage, never data
            sales:         [CONNECT, METADATA]
          granted_to: [denodo_developer_global]  # pre-existing umbrella role
        sales_rep:
          privileges:
            sales: [CONNECT, EXECUTE]

  WHAT IT DOES
    1. creates the declared roles that do not exist yet (checked against LIST ROLES);
    2. for every (role, VDB) pair named in THIS project's block: grants the declared
       privileges and REVOKES the others -> the YAML converges, removing a privilege
       from it actually removes it in Denodo;
    3. grants the role INTO each `granted_to` parent (`ALTER ROLE parent GRANT ROLE
       child`), which is the direction that makes a user of the parent inherit the
       child's privileges — verified: user -> parent -> child -> reads the gold.

  SCOPE — deliberately narrow:
    - only the VDBs named in this project's own block, so two data products can grant
      the same role (`role_denodo_developer`, `buyer`, …) on their own VDBs without
      fighting;
    - `granted_to` is ADDITIVE only: the parent role pre-exists and may legitimately
      carry children owned by other projects, so we never revoke a membership;
    - NOT managed here, on purpose: users, user->role assignment (`ALTER USER … GRANT
      ROLE`), and server-level admin roles.

  Verified on VDP 9.4.7: `CREATE ROLE` fails if the role exists and there is no
  `IF NOT EXISTS` (hence the LIST ROLES probe); re-granting an identical privilege,
  revoking one that was never granted, and re-granting an existing role membership are
  all accepted as no-ops — which is what makes this safely repeatable.
#}
{% macro denodo_apply_roles() -%}
    {%- set security = (var('denodo', {}).get('security') or {}) -%}
    {%- if not execute or not security -%}
        SELECT 1
    {%- else -%}

        {#- every privilege this macro is allowed to manage: what is not declared for a
            (role, VDB) pair gets revoked. This is every privilege VDP 9.4.7 accepts at
            DATABASE level. Each one must be named: measured, `REVOKE CREATE` leaves
            CREATE_VIEW, CREATE_FOLDER, CREATE_DATA_SOURCE and CREATE_DATA_SERVICE in
            place, and `REVOKE WRITE` leaves INSERT, UPDATE and DELETE. ADMIN is
            deliberately absent. -#}
        {%- set managed_privileges = var('denodo', {}).get('managed_privileges',
                ['CONNECT', 'CREATE', 'CREATE_DATA_SOURCE', 'CREATE_VIEW', 'CREATE_DATA_SERVICE',
                 'CREATE_FOLDER', 'FILE', 'EXECUTE', 'METADATA', 'WRITE',
                 'INSERT', 'UPDATE', 'DELETE']) -%}

        {#- all VDBs this project governs = those named in its own block -#}
        {%- set project_vdbs = [] -%}
        {%- for role, spec in security.items() -%}
            {%- for vdb in (spec.get('privileges') or {}) -%}
                {%- if vdb not in project_vdbs -%}{%- do project_vdbs.append(vdb) -%}{%- endif -%}
            {%- endfor -%}
        {%- endfor -%}

        {%- set existing = [] -%}
        {%- for row in run_query('LIST ROLES').rows -%}
            {%- do existing.append(row[0] | lower) -%}
        {%- endfor -%}

        {%- set statements = [] -%}
        {%- for role, spec in security.items() -%}

            {%- if role | lower not in existing -%}
                {%- do statements.append(
                    "CREATE ROLE " ~ role ~ " '" ~ (spec.get('description', 'managed by dbt') | replace("'", "''")) ~ "'") -%}
            {%- endif -%}

            {%- set declared = spec.get('privileges') or {} -%}
            {%- for vdb in project_vdbs -%}
                {%- set granted = declared.get(vdb) or [] -%}
                {%- set revoked = [] -%}
                {%- for p in managed_privileges -%}
                    {%- if p not in granted -%}{%- do revoked.append(p) -%}{%- endif -%}
                {%- endfor -%}
                {%- if granted -%}
                    {%- do statements.append('ALTER ROLE ' ~ role ~ ' GRANT ' ~ granted | join(', ') ~ ' ON ' ~ vdb) -%}
                {%- endif -%}
                {%- if revoked -%}
                    {%- do statements.append('ALTER ROLE ' ~ role ~ ' REVOKE ' ~ revoked | join(', ') ~ ' ON ' ~ vdb) -%}
                {%- endif -%}
            {%- endfor -%}

            {%- for parent in (spec.get('granted_to') or []) -%}
                {%- if parent | lower not in existing -%}
                    {%- do exceptions.raise_compiler_error(
                        "denodo_apply_roles: parent role '" ~ parent ~ "' does not exist. It is expected to "
                        ~ "pre-exist (umbrella role holding actual people) and is never created here.") -%}
                {%- endif -%}
                {%- do statements.append('ALTER ROLE ' ~ parent ~ ' GRANT ROLE ' ~ role) -%}
            {%- endfor -%}

        {%- endfor -%}

        {%- do log("denodo_apply_roles: " ~ security | length ~ " role(s), "
                   ~ project_vdbs | length ~ " VDB(s), " ~ statements | length ~ " statement(s)", info=True) -%}
        {{ statements | join(';\n') }}
    {%- endif -%}
{%- endmacro %}


{#
  ---------------------------------------------------------------------------
   denodo_audit — what drifted in the VDBs this project governs
  ---------------------------------------------------------------------------
      dbt run-operation denodo_audit --profiles-dir ..

  Deliberately NOT a hook. It reads the server state role by role (`LIST ROLES` + one
  `DESC VQL ROLE` each — there is no catalog view for privileges), which is far too
  expensive to run on every `dbt run`. Nightly or in CI is the place.

  Report-only, on purpose. An access granted at 3am by an admin during an incident can
  be legitimate; a build that silently revokes it is worse than the drift. This prints,
  a human decides.

  Five checks, scoped to the VDBs of THIS project:

   1. ROLES holding privileges on our VDBs that the YAML does not declare — the blind
      spot of `denodo_apply_roles`, which only ever touches declared roles. VIEW-level
      grants are flagged too: they show in no database-level declaration.
   1b. USERS holding a privilege granted DIRECTLY to them on our VDBs. This is the
      dangerous one. Denodo attaches the restrictions of a policy to the audience that
      triggers it; with an audience written in roles, a privilege that does not come
      through a role carries no restriction (documented in the Administration Guide,
      "Global Security Policies"). Measured on 9.4.7: with `EXECUTE` granted directly
      on a published view, a user read a masked column in clear and a row-filtered
      view in full.
   2. ORPHAN VIEWS: derived views in our VDBs that no dbt model produces — typically a
      model deleted from the project (dbt never drops what it stops building) or a view
      hand-built in Design Studio. `GET_VIEWS().view_type` is an INTEGER: 0 = base view
      (the VQL layer, legitimately not dbt's), 1 = derived.
   3. TAG assignments our YAML does not declare. Assignments are not readable from
      `DESC VQL TAG`; they appear inside `DESC VQL DATABASE "<vdb>"`, as
      `<column> TAGS (<tag>)` in a column list, or `TAGS (<tag>) AS SELECT` for a whole
      view — hence the statement-context parsing below.
   4. WHICH RULES actually govern our tags. Policies are not owned by dbt — they are
      cross-product objects declared once by the governance federation. But a product
      owner still needs to answer "which rules protect my columns?", and above all to
      see a rule that is DISABLED while governing one of our tags: the policy exists,
      it looks fine in a listing, and it applies to nothing. That one is reported as a
      warning, not as information.
#}
{% macro denodo_audit() -%}
    {%- if not execute -%}{{ return('') }}{%- endif -%}

    {%- set security = (var('denodo', {}).get('security') or {}) -%}

    {#- our VDBs = those of the project's models, plus those named in `security` -#}
    {%- set my_vdbs = [] -%}
    {%- for node in graph.nodes.values() if node.resource_type == 'model' -%}
        {%- if node.database and node.database not in my_vdbs -%}{%- do my_vdbs.append(node.database) -%}{%- endif -%}
    {%- endfor -%}
    {%- for role, spec in security.items() -%}
        {%- for vdb in (spec.get('privileges') or {}) -%}
            {%- if vdb not in my_vdbs -%}{%- do my_vdbs.append(vdb) -%}{%- endif -%}
        {%- endfor -%}
    {%- endfor -%}

    {#- what the project declares: relations, and tag -> relation[.column] -#}
    {%- set managed = [] -%}
    {%- set declared_tags = [] -%}
    {%- for node in graph.nodes.values() if node.resource_type == 'model' -%}
        {%- set relation = (node.database ~ '.' ~ (node.alias or node.name)) | lower -%}
        {%- do managed.append(relation) -%}
        {%- for t in (node.tags or []) -%}
            {%- do declared_tags.append((t ~ '@' ~ relation) | lower) -%}
        {%- endfor -%}
        {%- for col_name, col in (node.columns or {}).items() -%}
            {%- for t in (col.get('tags') or []) -%}
                {%- do declared_tags.append((t ~ '@' ~ relation ~ '.' ~ col_name) | lower) -%}
            {%- endfor -%}
        {%- endfor -%}
    {%- endfor -%}

    {%- do log("=" * 72, info=True) -%}
    {%- do log("Denodo AUDIT: VDBs governed by this project: " ~ my_vdbs | join(', '), info=True) -%}
    {%- do log("=" * 72, info=True) -%}
    {%- set findings = [] -%}

    {#- ------------------------------------------------------------------ 1. roles -#}
    {%- for row in run_query('LIST ROLES').rows -%}
        {%- set role = row[0] -%}
        {%- set declared_vdbs = (security.get(role, {}).get('privileges') or {}) -%}
        {%- for line in run_query('DESC VQL ROLE "' ~ role ~ '"').rows[0][0].split('\n') -%}
            {%- set l = line | trim | replace(';', '') -%}
            {%- if l.startswith('GRANT ') and ' ON ' in l -%}
                {%- set privileges = l.split(' ON ')[0][6:] | trim -%}
                {%- set target = l.split(' ON ')[1] | trim -%}
                {%- set target_vdb = target.split('.')[0] -%}
                {%- if target_vdb in my_vdbs -%}
                    {%- if '.' in target -%}
                        {%- do findings.append("ROLE  " ~ role ~ ": VIEW-level privilege on " ~ target ~ " (" ~ privileges
                                               ~ "): granted on one view, so it shows in no database-level declaration") -%}
                    {%- elif target_vdb not in declared_vdbs -%}
                        {%- do findings.append("ROLE  " ~ role ~ ": access to " ~ target_vdb ~ " (" ~ privileges
                                               ~ ") NOT declared in the YAML") -%}
                    {%- endif -%}
                {%- endif -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endfor -%}

    {#- ------------------------------------------------- 1b. users, direct privileges -#}
    {#- `includeUserPrivileges` is required: without it DESC VQL USER returns the bare
        CREATE USER. The statement embeds the password hash: only the GRANT lines are
        read here, and nothing of it is ever logged. -#}
    {%- for row in run_query('LIST USERS').rows -%}
        {%- set user = row[0] -%}
        {%- set user_vql = run_query('DESC VQL USER "' ~ user ~ '" (' ~ "'includeUserPrivileges' = 'yes'" ~ ')').rows[0][0] -%}
        {%- for line in user_vql.split('\n') -%}
            {%- set l = line | trim | replace(';', '') -%}
            {%- if l.startswith('GRANT ') and ' ON ' in l -%}
                {%- set privileges = l.split(' ON ')[0][6:] | trim -%}
                {%- set target = l.split(' ON ')[1] | trim -%}
                {%- if target.split('.')[0] in my_vdbs -%}
                    {%- do findings.append("USER  " ~ user ~ ": DIRECT privilege on " ~ target ~ " (" ~ privileges
                                           ~ "): not through a role, so the policies written on roles do not restrict it") -%}
                {%- endif -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endfor -%}

    {#- ------------------------------------------------------------- 2. orphan views -#}
    {%- for vdb in my_vdbs -%}
        {%- for row in run_query("SELECT name, view_type FROM GET_VIEWS() WHERE input_database_name = '" ~ vdb ~ "'").rows -%}
            {%- if row[1] != 0 and (vdb ~ '.' ~ row[0]) | lower not in managed -%}
                {%- do findings.append("VIEW  " ~ vdb ~ "." ~ row[0]
                                       ~ ": derived view that no dbt model produces (orphan?)") -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endfor -%}

    {#- --------------------------------------------------------------------- 3. tags -#}
    {%- for vdb in my_vdbs -%}
        {%- set current = namespace(view='') -%}
        {%- for line in run_query('DESC VQL DATABASE "' ~ vdb ~ '"').rows[0][0].split('\n') -%}
            {#- Blank out the string literals first: a column line reads
                `email (description = '… (tag class_pii).') TAGS (class_pii),` and a
                description written by persist_docs may mention a tag, or even `TAGS (`. -#}
            {%- set l = modules.re.sub("'(?:[^']|'')*'", "''", line | trim) -%}
            {#- `DESC VQL DATABASE` writes `CREATE VIEW <name> FOLDER = …`, not
                `CREATE OR REPLACE VIEW` — match both, and never mistake the header
                `CREATE OR REPLACE TAGS (…)` of the TAGS section for a column tag. -#}
            {%- if ' VIEW ' in l and l.startswith('CREATE') -%}
                {%- set current.view = l.split(' VIEW ')[1] | trim | replace('"', '') -%}
                {%- set current.view = current.view.split(' ')[0].split('(')[0] | lower -%}
            {%- endif -%}
            {%- if 'TAGS (' in l and current.view and not l.startswith('CREATE') -%}
                {%- set head = l.split('TAGS (')[0] | trim -%}
                {%- set tags = l.split('TAGS (')[1].split(')')[0] -%}
                {#- the column name is the FIRST token of the line; an empty head is a
                    whole-view tag (`TAGS (x) AS SELECT …`) -#}
                {%- set column = head.split(' ')[0] | replace('"', '') | lower if head else '' -%}
                {%- for t in tags.split(',') -%}
                    {%- set key = ((t | trim) ~ '@' ~ vdb ~ '.' ~ current.view ~ ('.' ~ column if column else '')) | lower -%}
                    {%- if key not in declared_tags -%}
                        {%- do findings.append("TAG   " ~ (t | trim) ~ " on " ~ vdb ~ "." ~ current.view
                                               ~ ('.' ~ column if column else ' (whole view)')
                                               ~ ": NOT declared in the YAML") -%}
                    {%- endif -%}
                {%- endfor -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endfor -%}

    {#- ------------------------------------------------- 4. rules governing our tags -#}
    {%- set governed = (var('denodo', {}).get('governance_tags') or []) -%}
    {%- set our_tags = [] -%}
    {%- for t in declared_tags -%}
        {%- set tag = t.split('@')[0] -%}
        {%- if tag not in our_tags and (not governed or tag in governed) -%}{%- do our_tags.append(tag) -%}{%- endif -%}
    {%- endfor -%}
    {%- if our_tags | length > 0 -%}
        {%- set rules = [] -%}
        {%- for row in run_query('LIST GLOBAL_SECURITY_POLICIES').rows -%}
            {%- set pol = row[0] -%}
            {%- set vql = run_query('DESC VQL GLOBAL_SECURITY_POLICY "' ~ pol ~ '"').rows[0][0] -%}
            {%- set hit = [] -%}
            {%- for tag in our_tags -%}
                {%- if tag in vql -%}{%- do hit.append(tag) -%}{%- endif -%}
            {%- endfor -%}
            {%- if hit | length > 0 -%}
                {%- set off = 'ENABLED = FALSE' in (vql | upper) -%}
                {%- if off -%}
                    {%- do findings.append("RULE  " ~ pol ~ ": DISABLED while it governs "
                                           ~ hit | join(', ') ~ ": the rule exists and applies to nothing") -%}
                {%- else -%}
                    {%- do rules.append(pol ~ "  (" ~ hit | join(', ') ~ ")") -%}
                {%- endif -%}
            {%- endif -%}
        {%- endfor -%}
        {%- do log("Active rules on our tags (" ~ our_tags | join(', ') ~ "):", info=True) -%}
        {%- if rules | length == 0 -%}
            {%- do log("  none: our columns are tagged but no policy protects them", info=True) -%}
        {%- else -%}
            {%- for r in rules -%}{%- do log("  . " ~ r, info=True) -%}{%- endfor -%}
        {%- endif -%}
        {%- do log("", info=True) -%}
    {%- endif -%}

    {%- if findings | length == 0 -%}
        {%- do log("No drift detected.", info=True) -%}
    {%- else -%}
        {%- for f in findings -%}{%- do log("  " ~ f, info=True) -%}{%- endfor -%}
        {%- do log("-" * 72, info=True) -%}
        {%- do log(findings | length ~ " finding(s). Report only: nothing was modified.", info=True) -%}
    {%- endif -%}
{%- endmacro %}
