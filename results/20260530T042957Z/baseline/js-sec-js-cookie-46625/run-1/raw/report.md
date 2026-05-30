## Confirmed but not fixed
- JSCOOKIE-001 · high · security · src/assign.mjs:5 · removed `__proto__` guard lets `assign` set target's prototype from untrusted attributes (prototype pollution → cookie attribute injection)
