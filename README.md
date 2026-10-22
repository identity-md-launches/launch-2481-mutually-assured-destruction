# Mutually Assured Destruction (MAD)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum mainnet.

| Parameter | Value |
| --- | --- |
| Solidity contract | `MADToken` (`src/MADToken.sol`) |
| Token name | `Mutually Assured Destruction` |
| Token symbol | `MAD` |
| Decimals | 18 |
| Total supply | 1,000,000,000 MAD = `1000000000000000000000000000` minor units |
| Minted to | `msg.sender` of the constructor (the launch factory), once, in the constructor |
| Constructor arguments | none |
| Owner / admin | none |
| Compiler | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"`, `cbor_metadata = false` |

## What the token does

`MADToken` inherits the unmodified OpenZeppelin v5.4.0 `ERC20` and adds nothing but constants and a
constructor that mints the whole supply to the deployer. Every transfer moves exactly the amount
requested. There is:

- no owner, minter, upgrade path or `initialize`: the supply can never grow after deployment;
- no pause, blacklist, freeze, lock, seize, fee or burn-on-transfer: no privileged hand can move or
  freeze a holder's balance;
- no `delegatecall`, `callcode`, `selfdestruct`, no external calls and no `receive`/`fallback`:
  the contract cannot hold ETH and its constructor touches no other contract, so it deploys on an
  empty chain.

Public constants expose the configuration on chain: `TOKEN_NAME`, `TOKEN_SYMBOL`, `DECIMALS`,
`TOTAL_SUPPLY`.

## Assumptions

- **The deployer receives everything.** At launch the IdentityMD `ProjectFactory` deploys the token
  through `launchCustom`, so `msg.sender` in the constructor is the factory and the factory holds the
  full supply. The factory then forwards 10% to the launch's MerkleDistributor, seeds the pool with
  80% (`economics.poolBps = 8000`) and sends the remaining 10% to `economics.remainderTo`
  (`0x1ee3ffadfe138415a2ddaedeebe5f46616fa413d`). Nothing in this repository is allocated any of
  it. If the contract is ever deployed by any other account, that account receives the whole supply.
- **No exemptions are needed.** Because transfers are untaxed and unrestricted, the token does not
  take `$factory`, `$poolManager` or `$launchNumber` as constructor arguments; all launch flows
  (distributor transfer, claims, pool seed, swaps) move exactly what they say.
- **Supply is fixed for good.** There is no burn function either. Holders can still take tokens out
  of circulation by sending them to an address nobody controls, but `totalSupply()` never changes.
- **Standard ERC-20 approval semantics.** `approve` overwrites the previous allowance (the known
  approve race applies, as with every plain ERC-20); an allowance of `type(uint256).max` is treated
  as infinite and is not decremented, following OpenZeppelin's convention.
- **The pool is the launch's business.** Chain id 1, pairing with FWA
  (`0xa0df17b5ac76ababa36e1450e2cbcd18a620c845`), fee 12500, tick spacing 60 and the opening market
  cap of 2,000,000 FWA are launch-policy values the manifest step records; the token has no
  knowledge of them and needs none.

## Deployment parameters

The launch manifest (written by IdentityMD's manifest step after acceptance, not by this repository)
describes the token as:

- `token.contract`: `MADToken`
- `token.name`: `Mutually Assured Destruction`
- `token.symbol`: `MAD`
- `token.decimals`: `18`
- `token.constructorArgs`: `[]`
- `token.totalSupply`: `1000000000000000000000000000`
- `contracts`: `[]` (no application contracts)

The bytecode must be built with the `foundry.toml` in this repository (solc 0.8.26, optimizer 200
runs, no metadata hash) so the deployed bytes match the attested build.

`script/DeployMADToken.s.sol` is a reviewable rehearsal script. Its `deploy()` function takes no
configuration and is exercised by the tests; `run()` only wraps it in a broadcast for a local
Anvil or fork rehearsal. It reads no environment variables. It is **not** how the launch deploys the
token: the factory deploys the creation code itself, and this assignment authorises no transactions.

## After launch

There are no owner-settable values: the contract has no owner and no setters, so there is nothing to
configure after deployment.

## Operational responsibilities

- **IdentityMD (deployer and factory):** build from this source with the pinned configuration,
  deploy through the factory, forward the swarm share, seed the pool and forward the remainder.
  Explorer verification of the deployed source is the deployer's step.
- **Requester:** custody of the `remainderTo` wallet and whatever they do with the 10% it receives.
  No key held by the requester has any power over the token itself.
- **Holders:** custody of their own keys and care with approvals. No one can recover tokens sent
  to a wrong address, and no one can freeze, seize or mint.
- **Nobody:** there is no upgrade, pause or admin role to hand to a multisig, because none exists.

## Security notes

The eth-security checklist was applied while writing and reviewing: no reentrancy surface (no
external calls), no access control to misconfigure (no privileged functions), no arithmetic outside
the audited OpenZeppelin ERC20, no `tx.origin`, no `selfdestruct`/`delegatecall`, no ETH handling,
no oracle or randomness. Tests scan the runtime bytecode for `DELEGATECALL`, `CALLCODE` and
`SELFDESTRUCT` and check the EIP-170 size limit. Tools run: `forge build`, `forge test` (including
the verifier's fuzz seed) and `forge fmt --check`. Slither and Mythril were not run in this
assignment. Passing tests are not an audit; an independent adversarial review is still the right
step before anything that holds other people's funds, although this token holds none.

## Repository layout

```
foundry.toml                 compiler pins and build settings (solc 0.8.26, bytecode_hash = "none")
remappings.txt               forge-std and @openzeppelin/contracts remappings
src/MADToken.sol             the token
script/DeployMADToken.s.sol  reviewable deploy function (not used by the launch)
test/MADToken.t.sol          unit, failure, launch-shape, bytecode and fuzz tests
lib/forge-std                forge-std v1.9.7, vendored as plain files
lib/openzeppelin             OpenZeppelin Contracts v5.4.0 (contracts/ only), vendored as plain files
```

`lib/openzeppelin-contracts/` holds only an empty-of-purpose `.gitmodules` file left from the
vendoring step that the build environment would not let be deleted; it is not a submodule and
nothing references it.

## Running the checks

```
forge build
forge test
FOUNDRY_FUZZ_SEED=0x57282ac205a9a0870917ebf1a1f36fe1efadd89f52c4e553200f26a7c7490c21 forge test
forge fmt --check
```

## Test coverage

`test/MADToken.t.sol` covers:

- metadata, decimals and the exact supply constant;
- the constructor minting the whole supply to the deployer once (event, balance, independence of
  deployments);
- deployment through a CREATE2 factory stand-in with a predictable address, the factory holding the
  whole supply and paying out the 10% / 80% / 10% split exactly;
- the deploy script's `deploy()` function;
- successful `transfer`, `approve`, `transferFrom`, infinite allowance, allowance overwrite,
  zero-amount and self-transfer;
- failing `transfer`/`transferFrom`/`approve` with the exact OpenZeppelin custom errors
  (insufficient balance, insufficient allowance, zero-address receiver and spender);
- absence of any mint, ownership, upgrade, pause, blacklist, freeze, seize or `burnFrom` surface,
  from both a stranger and the deployer, with a holder still able to transfer afterwards;
- rejection of ETH sent to the contract;
- runtime size under EIP-170 and no reachable `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT`;
- fuzzed conservation of supply, exactness of transfers, allowance enforcement and balance
  enforcement.
