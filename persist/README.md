<div align="center">

# jeeflow-persist

**Workflow → business-table persistence for jeeflow — ARCHIVE / SYNC with field permissions.**

[![mooncakes](https://img.shields.io/badge/mooncakes-mldong%2Fjeeflow--persist-brightgreen)](https://mooncakes.io/docs/mldong/jeeflow-persist)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](../LICENSE)

</div>

`PersistPostInterceptor` copies form data out of running workflow instances into your own
business tables, driven entirely by the process definition — the role jeeflow-persist plays for
the MoonBit build of [jeeflow-moon](https://github.com/mldong/jeeflow-moon).

## Quickstart

```moonbit
let provider = @persist.InMemoryMetaProvider::new()
let meta = @persist.TableMeta::make("expense", "报销")
meta.add_field(@persist.FieldMeta::make("note", "VARCHAR(200)", "备注"))
provider.register(meta)

let interceptor = @persist.PersistPostInterceptor::make(provider, my_writer)
ctx.register_interceptor(interceptor.as_interceptor())   // order = 100 (post)
```

Process definition drives everything:

```json
{"persistMode": "ARCHIVE", "relTableName": "expense"}
```

- **ARCHIVE** — at the end node, on `FINISHED` + agree (`submitType=1`), insert the full `f_*`
  form once; idempotent by the `process_instance_id` key.
- **SYNC** — insert at start → update at each task (business fields filtered by the target
  node's `field.PERMISSION_*`: readonly/hidden never write through) → final-state update at the
  end; a `{nodeId}_{state}` status column is probed automatically.
- **Safety** — dynamic table names are validated (alnum+underscore, `wf_`/`sys_`/… prefixes
  refused) and failures are loud, never silent.

## License

Apache-2.0 — part of [jeeflow-moon](https://github.com/mldong/jeeflow-moon).
