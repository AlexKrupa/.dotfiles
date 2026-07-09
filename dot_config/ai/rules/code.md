---
paths:
  - "**/*.{kt,kts,java,groovy,swift,py,ts,tsx,js,jsx,go,rs,rb,c,cpp,h,hpp,cs,dart,lua,php,sql}"
  - "**/{Dangerfile,Dockerfile,Makefile}"
---

- Match existing code style, not your preference
- Formatting follows the "rectangle rule": "each subtree gets its own bounding rectangle, containing
  all of that subtree’s text and none of any other subtree’s"
- Guard clauses over nested conditionals
- Code comments (inline and doc):
  - Explain WHY, not WHAT
  - Exist only when the WHY is not obvious
  - Are BRIEF and only provide relevant information, not transient conversation context
- Include context in logs and error messages
- Only clean up things your changes made unused
