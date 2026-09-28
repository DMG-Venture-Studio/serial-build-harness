# .claude/serial-build.json

The one file that turns the plugin's hooks on for a project. Without it every hook exits at once
and silently, so installing the plugin user-wide never touches an unrelated repository. It is
committed, so every clone gets the same guards. It is plain JSON: the hooks read it with awk, so it
needs no jq or python on the machine.

```json
{
  "version": 1,
  "owner": { "name": "Ada" },
  "inbox": "claude_outputs",
  "generated": [
    { "path": "api/openapi.gen.ts", "regenerate": "npm run gen:api" }
  ],
  "checks": {
    "on_edit": [
      { "name": "lint", "paths": ["src/**", "tests/**"], "run": "npx eslint --quiet \"$SB_FILE\"" }
    ],
    "on_stop": [
      { "name": "unit tests", "paths": ["src/**", "tests/**"], "run": "npm test --silent" }
    ]
  },
  "red": { "test_paths": ["tests/**"] }
}
```

| Field | Required | Read by | Meaning |
|---|---|---|---|
| `version` | yes | check-config | Always `1`. |
| `enabled` | no | every hook | `false` switches every hook off for this project without deleting the file. |
| `owner.name` | yes | every skill | The product owner: the person who runs each gate's demo and whose acceptance sentence moves a gate to done. |
| `inbox` | no | session-start, inbox hooks | Folder, relative to the project root, other sessions drop files into. Listed at session start; a session that touched it cannot stop while it holds items. Absent or `""`: inbox hooks off. |
| `generated` | no | guard-generated | List of `{path, regenerate}`. An Edit or Write to a file matching `path` is refused, and the refusal names `regenerate`. |
| `checks.on_edit` | no | edit-checks | List of `{name, paths, run}`. After each Edit or Write to a file matching `paths`, `run` runs with `sh` from the project root, with `SB_FILE` set to the edited path; a non-zero exit is fed back to the session. `paths` absent: every file in the project. |
| `checks.on_stop` | no | stop-checks | List of `{name, paths, run}`. When the session ends its turn and git shows uncommitted changes under `paths` that `run` has not yet been run on, `run` runs; a failure keeps the session working once per distinct set of changes. Needs a git work tree. |
| `red.test_paths` | for the red lane | red-fence, red-guard, /serial-build:red | Patterns for the files the red-breaker agent may write. Without it `/serial-build:red` refuses to run, and so no gate can hand off. |

Patterns are relative to the project root. Only `*` is a wildcard, and it also crosses `/`; `**`
and `**/` mean the same as `*`: `src/**` matches every file under `src/`, and `**/*.test.ts`
matches a test file at any depth. `[`, `]`, and `?` match themselves, so `app/[id].ts` is listed
as it is named.

Check a config, and read in plain words what each hook will do with it:
`sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-config.sh"` from the project root.
