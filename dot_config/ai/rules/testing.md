---
paths:
  - "**/*{Test,test,Spec,spec}*"
---

- Test doubles: prefer real implementations or fakes over mocks
- Test names: prefer active voice, 3rd person; never start with "should"
- Test body: visually separate setup/action/assertion in longer tests, but without section comments
- Test class/spec structure: read top-to-bottom - put setup and relevant context (private methods) before the tests
