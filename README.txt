RealHedge — Task 1 Supporting Source Code
===========================================

Files included in this submission:

  RealHedge0Chain.py           The core PoA blockchain (Block, PoAValidator,
                           Blockchain classes). This is the assessed
                           deliverable for Questions 1 and 2 of the report
                           — block structure, hashing, chain validation,
                           and ECDSA-based Proof-of-Authority consensus.

  validator.py             Independent validator nodes that evaluate a
                           proposed transaction against business rules
                           and cast a signed approve/reject decision.

  mempool.py               Tracks each submitted transaction through its
                           lifecycle: PENDING, UNDER_INSPECTION, APPROVED,
                           CONFIRMED, or REJECTED.

  transaction_manager.py   Orchestrates the above: collects validator
                           votes, updates the mempool, and only calls
                           onward to Ethereum once approval is unanimous.

These four files correspond to the architecture described in Section 4
and demonstrated in Section 6 of the accompanying report.

---

Files NOT included, and why
----------------------------

validator.py and transaction_manager.py both import ethereum_client.py,
which is not included here. ethereum_client.py, config.py and demo.py
are omitted because they require a live Ganache instance and deployed
Solidity contracts (USDX, RealEstateVault) to run — without that live
environment they cannot execute, and the addresses/transaction hashes
they would produce are specific to one local Ganache session, not
reproducible or meaningful on another machine.

The actual behavioural evidence these files produce when run against
Ganache — real Ethereum transaction hashes, block numbers, and
confirmation statuses — is already captured as screenshots inside the
report itself (Figures 15–26), so no code needs to be re-run to verify
that behaviour.

RealHedge0Chain.py itself has no such dependency: it only requires the
`cryptography` package and can be run standalone (see the separate
blockchain_only_demo.py, referenced in the report, for a fully
self-contained demonstration with no Ganache/web3 dependency at all).
