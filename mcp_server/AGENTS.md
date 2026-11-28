# mcp_server

Read `docs/mcp-server.md` before changing a file here.

- A tool never takes a uid; `UserScope` is the only route to `users/{uid}`.
- No tool returns heart rate: workout reads pass through `stripHealthData`.
- The only writes under `users/{uid}` are `save_routine`'s routine and its new
  exercises. No tool deletes.
- A routine's exercise name, kind, parameters and muscles come from the exercise
  document, never from the draft.
- The token check and the budgets come before any Google call.
- The dev token is never read in production mode.
- `GymMcpServer` owns the session map; `StreamableMcpServer` cannot tell a tool
  its user.
- `just mcp-test` needs `just up` stopped: same ports.
