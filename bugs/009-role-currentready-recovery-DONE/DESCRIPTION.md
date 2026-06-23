# Bug 009: Role eviction currentReady recovery must ignore stale tracker entries

## Status

DONE

## Problem

Bug 007 fixed stale `currentReady` recovery for eviction webhook decisions and
included unit coverage for Role protection. The previous Kind verification,
however, focused on ServingGroup protection. We need an independent Role-level
bug to verify whether stale Role tracker entries can still keep
`currentReady`/ready role instances below the real recovered state.

Potential problematic scenario:

1. A `ModelServing` uses `protectionLevel: Role` with
   `roleMinAvailable.decode: 2`.
2. The `decode-0` role instance is evicted and later recovered.
3. A stale tracker entry still marks `decode-0` disrupted even though live Pods
   show it is Ready and the original trigger UID is gone.
4. A second eviction of `decode-1` could be denied if Role-level cleanup does not
   refresh live Pod state before computing ready role instances.

Additional reproduction reported from another environment:

- The workload has two roles, with one role configured for 2 replicas and another
  for 3 replicas.
- Role eviction logs show `readyInstances=1`, `observedInstances=1`, and
  `totalInstances=3`.
- This points to the Role admission path observing only the target role instance
  from the cached Pod list, even though three role instances should be
  considered. One log also shows the target Pod missing from the lister but
  present via live API GET, which confirms informer lag can leave peer Pods
  absent from the admission-time list.
- Pod ownership filtering should remain strict: a Pod without the current
  ModelServing ownerReference should not be counted as belonging to that
  ModelServing. The reported failure is addressed as informer cache lag, not as
  an ownerReference compatibility problem.

## Expected Behavior

When the live API proves the previously disrupted Role instance is Ready and the
old trigger Pod UID is absent, the webhook should remove the stale Role tracker
entry before admission computes ready role instances. A second eviction should
be allowed when the real ready role instance count is above `roleMinAvailable`.

When the informer cache observes fewer Role instances than the ModelServing spec
requires, the webhook should refresh Pods from the live API before computing
ready Role instances. A cached observation of only the target Pod must not deny
eviction when the live API shows enough ready peers.

## Environment Details

- Branch: `fix/009-role-currentready-recovery`
- Baseline branch: `fix/007-eviction-currentready-recovery`
- Verification target: local Kind cluster with eviction webhook enabled
