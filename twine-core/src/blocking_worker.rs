//! Workers that app calls synchronously wait on, including during shutdown.
//!
//! Swift's core transport runs at user-initiated `QoS`. Set the same `QoS` before a worker
//! does any work so channel replies, queue backpressure, and joins do not invert it.
//! Keep workers that callers never wait on outside this policy.

use std::io;
use std::thread::{self, JoinHandle, Scope, ScopedJoinHandle};

pub(crate) fn spawn<F, T>(name: String, work: F) -> io::Result<JoinHandle<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    thread::Builder::new().name(name).spawn(move || {
        set_qos();
        work()
    })
}

pub(crate) fn spawn_scoped<'scope, 'env, F, T>(
    scope: &'scope Scope<'scope, 'env>,
    name: String,
    work: F,
) -> io::Result<ScopedJoinHandle<'scope, T>>
where
    F: FnOnce() -> T + Send + 'scope,
    T: Send + 'scope,
{
    thread::Builder::new()
        .name(name)
        .spawn_scoped(scope, move || {
            set_qos();
            work()
        })
}

fn set_qos() {
    #[cfg(target_os = "macos")]
    {
        // SAFETY: This changes only the current worker's scheduling policy. The QoS class
        // and zero relative priority are valid, and no pointers or shared memory are involved.
        let result = unsafe {
            libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INITIATED, 0)
        };
        if result != 0 {
            let error = io::Error::from_raw_os_error(result);
            tracing::warn!(%error, "failed to set blocking core worker QoS");
        }
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    fn current_qos() -> u32 {
        let mut class = libc::qos_class_t::QOS_CLASS_UNSPECIFIED;
        // SAFETY: The thread is live, class points to writable storage, and the unused
        // relative-priority output is allowed to be null.
        let result = unsafe {
            libc::pthread_get_qos_class_np(
                libc::pthread_self(),
                &raw mut class,
                std::ptr::null_mut(),
            )
        };
        assert_eq!(result, 0);
        class as u32
    }

    #[test]
    fn worker_sets_user_initiated_qos_before_work_without_changing_the_caller() {
        let caller_qos = current_qos();
        let worker_qos = spawn("qos-test".into(), current_qos)
            .unwrap()
            .join()
            .unwrap();
        assert_eq!(
            worker_qos,
            libc::qos_class_t::QOS_CLASS_USER_INITIATED as u32
        );
        assert_eq!(current_qos(), caller_qos);
    }

    #[test]
    fn scoped_worker_sets_user_initiated_qos_before_borrowed_work() {
        let caller_qos = current_qos();
        let mut worker_qos = 0;
        thread::scope(|scope| {
            spawn_scoped(scope, "scoped-qos-test".into(), || {
                worker_qos = current_qos();
            })
            .unwrap()
            .join()
            .unwrap();
        });
        assert_eq!(
            worker_qos,
            libc::qos_class_t::QOS_CLASS_USER_INITIATED as u32
        );
        assert_eq!(current_qos(), caller_qos);
    }
}
