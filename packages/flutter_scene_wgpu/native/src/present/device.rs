//! The presenters' view of the process's shared wgpu device (the one the
//! device API hands out), and the thread that turns finished GPU work into
//! callbacks.

use std::sync::mpsc::{channel, Sender};
use std::sync::Mutex;

/// One adapter, device and queue, plus the completion poller.
pub struct Gpu {
    pub instance: wgpu::Instance,
    pub adapter: wgpu::Adapter,
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    poke: Mutex<Sender<()>>,
}

impl Gpu {
    /// Takes the process's shared device, opening it on the adapter
    /// [choose] returns when nothing opened it yet, and starts the
    /// completion poller.
    pub fn open(
        choose: impl FnOnce() -> Result<(wgpu::Instance, wgpu::Adapter), String>,
    ) -> Result<Gpu, String> {
        let state = crate::shared_device(|| {
            choose().map_err(|e| crate::error::FswError::new(crate::error::Code::NoAdapter, e))
        })
        .map_err(|e| e.message)?;
        let (instance, adapter, device, queue) = (
            state.instance.clone(),
            state.adapter.clone(),
            state.device.clone(),
            state.queue.clone(),
        );

        let (poke, wake) = channel::<()>();
        let poll_device = device.clone();
        std::thread::Builder::new()
            .name("fsw-present-poll".into())
            .spawn(move || {
                // Each poke means a submission was made; waiting for the most
                // recent one fires the on_submitted_work_done callbacks of
                // every earlier submission too.
                while wake.recv().is_ok() {
                    while wake.try_recv().is_ok() {}
                    let _ = poll_device.poll(wgpu::PollType::wait_indefinitely());
                }
            })
            .map_err(|e| format!("cannot start the poll thread: {e}"))?;

        Ok(Gpu {
            instance,
            adapter,
            device,
            queue,
            poke: Mutex::new(poke),
        })
    }

    /// Wakes the poller after a submit so its completion callbacks fire
    /// as soon as the GPU finishes.
    pub fn poke(&self) {
        let _ = self.poke.lock().unwrap().send(());
    }

    /// Blocks until all submitted work has finished and its callbacks ran.
    pub fn wait_idle(&self) {
        let _ = self.device.poll(wgpu::PollType::wait_indefinitely());
    }

    /// The backend name, for the example's status line.
    pub fn backend_name(&self) -> String {
        format!("{:?}", self.adapter.get_info().backend)
    }
}
