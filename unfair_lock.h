#if __IPHONE_OS_VERSION_MAX_ALLOWED > 100000
// New SDK
#include <os/lock.h>
#define unfair_lock os_unfair_lock
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 100000
// Only targeting new iOS, always use unfair locks
#define unfair_lock_lock os_unfair_lock_lock
#define unfair_lock_trylock os_unfair_lock_trylock
#define unfair_lock_unlock os_unfair_lock_unlock
#else
// Support both at runtime
#import <libkern/OSAtomic.h>
static inline void unfair_lock_lock(unfair_lock *lock)
{
	if (&os_unfair_lock_lock != NULL) {
		os_unfair_lock_lock(lock);
	} else {
		OSSpinLockLock((volatile OSSpinLock *)lock);
	}
}
static inline bool unfair_lock_trylock(unfair_lock *lock)
{
	if (&os_unfair_lock_trylock != NULL) {
		return os_unfair_lock_trylock(lock);
	} else {
		return OSSpinLockTry((volatile OSSpinLock *)lock);
	}
}
static inline void unfair_lock_unlock(unfair_lock *lock)
{
	if (&os_unfair_lock_unlock != NULL) {
		os_unfair_lock_unlock(lock);
	} else {
		OSSpinLockUnlock((volatile OSSpinLock *)lock);
	}
}
#endif
#else
// Old SDK, fallback to using regular old spinlocks
#import <libkern/OSAtomic.h>
#define unfair_lock volatile OSSpinLock
#define unfair_lock_lock OSSpinLockLock
#define unfair_lock_trylock OSSpinLockTry
#define unfair_lock_unlock OSSpinLockUnlock
#endif