{#
  ============================================================================
   Override of a DBT-CORE macro (not of the dbt-denodo adapter)
  ============================================================================
  `generate_schema_name` is one of dbt-core's `generate_*_name` macros, which dbt only
  reads from the ROOT project: neither a package nor the adapter can supply it. Denodo
  will therefore never be able to ship it in its wheel — it is 3 lines to copy into
  every dbt-Denodo project (or, as here, into a folder shared through `macro-paths`).
#}

{#
  ---------------------------------------------------------------------------
   generate_schema_name — the schema IS the VDB, so stop typing it
  ---------------------------------------------------------------------------
  Denodo has no schemas: the only name that matters is the database (VDB). dbt's
  `schema` is therefore irrelevant to the generated VQL (the Denodo relation ignores
  it) — except to the CATALOG, which uses it as a VDB name. With a wrong schema,
  `dbt docs generate` no longer finds any of its views.

  Rather than declaring `+database` AND `+schema` side by side (two truths to keep in
  sync), we derive the latter from the former. One `+database` per folder is enough.

  Reminders:
    - by default dbt PREFIXES a custom schema (`<target.schema>_<custom>`); this macro
      is what neutralizes that behaviour;
    - dbt only reads `generate_*_name` in the ROOT project (ignored inside a package);
    - SOURCES do not go through this macro: keep their explicit `schema:`, otherwise dbt
      derives it from the source GROUP name.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {{ return(node.config.get('database') or target.database) }}
{%- endmacro %}
