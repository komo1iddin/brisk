//! Delivers backend events to Swift.
//!
//! The worker calls `Waker::wake` after every event it sends. That waker
//! repaints an `egui::Context`; here the context has no window, only a repaint
//! callback that signals the pump thread. The pump drains the backend,
//! converts the events, and hands them to the listener.
//!
//! egui calls the callback only when a repaint becomes *more* urgent than the
//! one already outstanding, and a windowless context never runs a pass that
//! would clear it. `Context::run_logic` consumes the outstanding request
//! without drawing, so the next wake reaches the callback again. A slow
//! timeout backs this up so an event can be late but never lost.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use zapfast::backend::{Backend, Waker};

use crate::client::EventListener;

/// Longest an event can wait if a wake signal were ever missed.
const SAFETY_POLL: Duration = Duration::from_secs(1);

/// The windowless context behind the waker, and the wake signal it raises.
pub struct Signal {
    context: egui::Context,
    wakes: Receiver<()>,
}

/// A waker wired to a signal channel, and that channel's receiving end.
pub fn waker() -> (Waker, Signal) {
    let (tx, rx) = mpsc::channel();
    let tx = Mutex::new(tx);
    let context = egui::Context::default();
    // Runs under egui's context lock: only signal, never touch the context.
    context.set_request_repaint_callback(move |_| {
        let _ = tx.lock().unwrap_or_else(|p| p.into_inner()).send(());
    });
    let waker = Waker::default();
    waker.attach(&context);
    (waker, Signal { context, wakes: rx })
}

pub struct Pump {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Pump {
    pub fn spawn(
        backend: Arc<Mutex<Backend>>,
        signal: Signal,
        listener: Arc<dyn EventListener>,
    ) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let thread = std::thread::Builder::new()
            .name("zapfast-bridge-pump".into())
            .spawn(move || run(&backend, &signal, &*listener, &stopping))
            .expect("unable to start the bridge event pump");
        Self {
            stop,
            thread: Some(thread),
        }
    }

    pub fn stop(mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn run(backend: &Mutex<Backend>, signal: &Signal, listener: &dyn EventListener, stop: &AtomicBool) {
    let rearm = egui::RawInput::default();
    // A wake or the safety poll runs a drain; only a dropped sender ends it.
    while !matches!(
        signal.wakes.recv_timeout(SAFETY_POLL),
        Err(RecvTimeoutError::Disconnected)
    ) {
        if stop.load(Ordering::SeqCst) {
            break;
        }
        // Coalesce a burst of wakes into one drain.
        while signal.wakes.try_recv().is_ok() {}

        let raw = backend.lock().unwrap_or_else(|p| p.into_inner()).poll();
        // Re-arm before converting, so a wake during conversion is not lost.
        let _ = signal.context.run_logic(&rearm, |_| {});

        let events: Vec<_> = raw.into_iter().filter_map(crate::events::convert).collect();
        if !events.is_empty() {
            listener.on_events(events);
        }
    }
}
