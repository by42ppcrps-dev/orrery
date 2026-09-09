**What changes**

**Why**

**Checks**
- [ ] `swift build` is clean
- [ ] the change has an audit check, and I broke the code once to see that check fail
- [ ] `.build/debug/Orrery --audit` passes (or the focused subset, named here)
- [ ] no new plaintext secret, no key logged, no key passed to another provider
- [ ] user-facing text names the real thing that happened
