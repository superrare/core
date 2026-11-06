"""Run inside the pinned Kontrol image. Reject incomplete or weakened APR proofs."""
import ast
import hashlib
import json
from pathlib import Path
from pyk.kast.inner import KToken
from pyk.proof.reachability import APRProof
from verify_lemmas import verify_lemmas

EXPECTED = {
    'CartAuthorizationProof': ['setUp', 'testProof_validAuthorization', 'testProof_platformRejectsUnapprovedDigest', 'testProof_sellerRejectsUnapprovedRoot', 'testProof_changedAmountRejectsOldApproval', 'testProof_signedLinesHashMustMatch', 'testProof_signedRouteHashMustMatch', 'testProof_signedActionsHashMustMatch', 'testProof_cachedRootCannotAuthorizeDifferentSeller', 'testProof_sellerRootRequiresMerkleMembership', 'testProof_platformApprovalUsesCartDomain'],
    'CartRevocationProof': ['setUp', 'testRevocation_sellerListingCancellation', 'testRevocation_sellerRootCancellation', 'testRevocation_sellerNonceInvalidation', 'testRevocation_otherListingCancellationIsIsolated', 'testRevocation_otherRootCancellationIsIsolated', 'testRevocation_otherNonceInvalidationIsIsolated', 'testRevocation_expiredOrder', 'testRevocation_expiredRoot', 'testRevocation_deadlinesInclusive'],
    'CartApprovalProof': ['setUp', 'testUnusedApprovalRevoked'],
    'CartSettlementProof': ['setUp', 'testNativeGroupedPayout', 'testNativeToWeth', 'testWethToNative', 'testErc20TemporaryApprovals'],
    'CartInventoryProof': ['setUp', 'testProof_duplicateLinesShareCapacity', 'testProof_twoPurchasesAndReplay', 'testProof_overfillAfterPurchaseRollsBack', 'testProof_duplicateLinesCannotIndividuallyReuseCapacity', 'testProof_payoutFailureRestoresReservation'],
}
output = Path('out/verified-results.json')
output.unlink(missing_ok=True)
lemma_evidence = verify_lemmas()
root = Path('out/proofs')
records = [json.loads(p.read_text()) for p in root.glob('*/proof.json')]
selected = []
for contract, functions in EXPECTED.items():
    for function in functions:
        matches = [r for r in records if f'{contract}.{function}(' in r.get('id', '')]
        if not matches:
            raise SystemExit(f'Missing proof: {contract}.{function}')
        selected.append(max(matches, key=lambda r: int(r['id'].rsplit(':', 1)[-1])))
seen = set()
results = []
def check_program(proof):
    """Bind the proof's initial executable program to the current harness artifact."""
    contracts = [name for name in EXPECTED if f'{name}.' in proof.id]
    if len(contracts) != 1:
        raise SystemExit(f'Unknown proof harness: {proof.id}')
    contract = contracts[0]
    artifact = Path('out') / f'{contract}.t.sol' / f'{contract}.json'
    expected = bytes.fromhex(json.loads(artifact.read_text())['deployedBytecode']['object'].removeprefix('0x'))
    program = proof.kcfg.node(proof.init).cterm.cell('PROGRAM_CELL')
    if not isinstance(program, KToken) or program.sort.name != 'Bytes':
        raise SystemExit(f'Non-concrete initial program: {proof.id}')
    try:
        actual = ast.literal_eval(program.token)
    except (ValueError, SyntaxError) as error:
        raise SystemExit(f'Cannot decode initial program: {proof.id}: {error}')
    if not isinstance(actual, bytes) or not expected or actual != expected:
        raise SystemExit(f'Initial program differs from current artifact: {proof.id}')
    return hashlib.sha256(actual).hexdigest()

def validate(proof_id):
    if proof_id in seen:
        return
    seen.add(proof_id)
    proof = APRProof.read_proof_data(root, proof_id)
    program_sha256 = check_program(proof)
    row = dict(id=proof.id, program_sha256=program_sha256, passed=proof.passed, pending=len(proof.pending), failing=len(proof.failing), bounded=len(proof.bounded), admitted=proof.admitted, bmc_depth=proof.bmc_depth)
    results.append(row)
    if not proof.passed or proof.pending or proof.failing or proof.bounded or proof.admitted or proof.bmc_depth is not None or proof.node_refutations:
        raise SystemExit(f'Incomplete or weakened proof: {row}')
    for child in proof.subproof_ids:
        validate(child)
for record in selected:
    validate(record['id'])
evidence = {'lemmas': lemma_evidence, 'proofs': results}
output.write_text(json.dumps(evidence, indent=2) + '\n')
print(json.dumps(evidence, indent=2))
