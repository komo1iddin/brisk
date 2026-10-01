//! The call going now, and its link to whatsapp-rust.
//!
//! Locks are held only to read or update the session, never across an await
//! or a call into Swift. Every task names the session it works for, so one
//! that finishes after its call ended (or after another began) changes
//! nothing but what it alone owns, such as a handle to terminate.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::Duration;

use whatsapp_rust::Client;
use whatsapp_rust::Jid;
use whatsapp_rust::async_channel;
use whatsapp_rust::voip::{CallEvent, CallHandle};
use whatsapp_rust::wacore::types::call::{CallAction, ElsewhereOutcome, IncomingCall};
use whatsapp_rust::wacore::types::events::{
    Event, EventHandler, EventInterest, EventKind, Subscription,
};

use super::phase::{self, CallPhase, Signal};
use super::{CallInfo, CallListener};

/// How long an outgoing call rings before we give up, as the phone does.
const RING_OUT: Duration = Duration::from_secs(60);
/// How long an incoming call may ring if the caller's terminate never comes.
const RING_IN: Duration = Duration::from_secs(90);
/// Microphone frames that may wait for the engine; older ones are dropped.
const MIC_QUEUE: usize = 3;
/// Playout frames that may wait for Swift.
const PLAYOUT_QUEUE: usize = 64;

pub(crate) struct Center {
    link: Mutex<Option<Link>>,
    listener: Mutex<Option<Arc<dyn CallListener>>>,
    call: Mutex<Option<Session>>,
    next_session: AtomicU64,
}

/// The worker's current client and the runtime it lives on.
struct Link {
    client: Weak<Client>,
    runtime: tokio::runtime::Handle,
    _events: Subscription,
}

struct Session {
    info: CallInfo,
    /// WhatsApp's id for the call, known from the offer or once ours is sent.
    wa_id: Option<String>,
    /// The offer of an incoming call, to answer or decline it.
    offer: Option<IncomingCall>,
    handle: Option<CallHandle>,
    microphone: Option<async_channel::Sender<Vec<i16>>>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|p| p.into_inner())
}

impl Center {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            link: Mutex::new(None),
            listener: Mutex::new(None),
            call: Mutex::new(None),
            next_session: AtomicU64::new(1),
        })
    }

    /// Called by the backend's hook, on its runtime, for each new client.
    pub fn link(self: &Arc<Self>, client: Arc<Client>) {
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            log::warn!("calls: the client arrived outside its runtime; calls are off");
            return;
        };
        let events = client.subscribe_handler(Arc::new(CallEvents(Arc::downgrade(self))));
        *lock(&self.link) = Some(Link {
            client: Arc::downgrade(&client),
            runtime,
            _events: events,
        });
        log::info!("calls: linked to the WhatsApp client");
    }

    pub fn set_listener(&self, listener: Arc<dyn CallListener>) {
        *lock(&self.listener) = Some(listener);
    }

    pub fn current(&self) -> Option<CallInfo> {
        lock(&self.call).as_ref().map(|s| s.info.clone())
    }

    fn client(&self) -> Option<(Arc<Client>, tokio::runtime::Handle)> {
        let link = lock(&self.link);
        let link = link.as_ref()?;
        Some((link.client.upgrade()?, link.runtime.clone()))
    }

    fn busy(call: &Option<Session>) -> bool {
        call.as_ref().is_some_and(|s| !s.info.phase.is_ended())
    }

    fn publish(&self, info: CallInfo) {
        let listener = lock(&self.listener).clone();
        if let Some(listener) = listener {
            listener.on_call(info);
        }
    }

    fn new_session(&self, chat: String, incoming: bool, video: bool, phase: CallPhase) -> Session {
        Session {
            info: CallInfo {
                session: self.next_session.fetch_add(1, Ordering::Relaxed),
                chat,
                incoming,
                video_offered: video,
                phase,
                muted: false,
            },
            wa_id: None,
            offer: None,
            handle: None,
            microphone: None,
        }
    }

    /// Moves session `id` by `signal`. When that ends it, the session gives
    /// up its handle (returned, for the caller to terminate if it must) and
    /// its microphone, which closes the engine's source.
    fn apply(&self, id: u64, signal: Signal) -> Option<CallHandle> {
        let (info, handle) = {
            let mut call = lock(&self.call);
            let session = call.as_mut().filter(|s| s.info.session == id)?;
            let next = phase::next(&session.info.phase, signal)?;
            session.info.phase = next;
            let mut handle = None;
            if session.info.phase.is_ended() {
                handle = session.handle.take();
                session.microphone = None;
                session.offer = None;
            }
            (session.info.clone(), handle)
        };
        log::info!("calls: {}", describe(&info.phase));
        self.publish(info);
        handle
    }

    fn session_for_wa_id(&self, wa_id: &str) -> Option<u64> {
        lock(&self.call)
            .as_ref()
            .filter(|s| s.wa_id.as_deref() == Some(wa_id))
            .map(|s| s.info.session)
    }

    // Outgoing

    pub fn place(self: &Arc<Self>, chat: String) -> bool {
        let Ok(peer) = chat.parse::<Jid>() else {
            return false;
        };
        if !(peer.is_pn() || peer.is_lid()) {
            return false;
        }
        let Some((client, runtime)) = self.client() else {
            return false;
        };
        let (microphone, source) = async_channel::bounded(MIC_QUEUE);
        let (sink, playout) = async_channel::bounded(PLAYOUT_QUEUE);
        let info = {
            let mut call = lock(&self.call);
            if Self::busy(&call) {
                return false;
            }
            let mut session = self.new_session(chat, false, false, CallPhase::Calling);
            session.microphone = Some(microphone);
            let info = session.info.clone();
            *call = Some(session);
            info
        };
        let id = info.session;
        log::info!("calls: placing a call");
        self.publish(info);

        let center = self.clone();
        runtime.spawn(async move {
            center.clone().play(playout);
            let started = client.voip().call(&peer).audio(source, sink).start().await;
            match started {
                Ok(handle) => {
                    if center.attach(id, handle.clone()) {
                        center.watch(id, &handle);
                        center.clone().ring_out(id);
                    } else {
                        // Hung up while the offer was going out.
                        let _ = handle.terminate().await;
                    }
                }
                Err(error) => {
                    log::warn!("calls: could not place the call");
                    center.apply(id, Signal::Failed(error.to_string()));
                }
            }
        });
        true
    }

    /// Gives up an outgoing call nobody answers.
    fn ring_out(self: Arc<Self>, id: u64) {
        tokio::spawn(async move {
            tokio::time::sleep(RING_OUT).await;
            if let Some(handle) = self.apply(id, Signal::TimedOut) {
                let _ = handle.terminate().await;
            }
        });
    }

    // Incoming

    fn ring(self: &Arc<Self>, offer: IncomingCall, chat: String, video: bool) {
        let info = {
            let mut call = lock(&self.call);
            if Self::busy(&call) {
                log::info!("calls: an offer arrived during a call; leaving it to the phone");
                return;
            }
            let mut session = self.new_session(chat, true, video, CallPhase::Ringing);
            session.wa_id = Some(offer.action.call_id().to_owned());
            session.offer = Some(offer);
            let info = session.info.clone();
            *call = Some(session);
            info
        };
        let id = info.session;
        log::info!("calls: incoming call");
        self.publish(info);
        let center = self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(RING_IN).await;
            let still_ringing = center
                .current()
                .is_some_and(|c| c.session == id && c.phase == CallPhase::Ringing);
            if still_ringing {
                center.apply(id, Signal::PeerTerminated { timeout: true });
            }
        });
    }

    pub fn answer(self: &Arc<Self>) {
        let Some((client, runtime)) = self.client() else {
            return;
        };
        let (microphone, source) = async_channel::bounded(MIC_QUEUE);
        let (sink, playout) = async_channel::bounded(PLAYOUT_QUEUE);
        let (info, offer) = {
            let mut call = lock(&self.call);
            let Some(session) = call.as_mut().filter(|s| s.info.phase == CallPhase::Ringing) else {
                return;
            };
            let Some(offer) = session.offer.clone() else {
                return;
            };
            session.info.phase = CallPhase::Connecting;
            session.microphone = Some(microphone);
            (session.info.clone(), offer)
        };
        let id = info.session;
        log::info!("calls: answering");
        self.publish(info);

        let center = self.clone();
        runtime.spawn(async move {
            center.clone().play(playout);
            let started = client
                .voip()
                .accept(&offer)
                .audio(source, sink)
                .start()
                .await;
            match started {
                Ok(handle) => {
                    if center.attach(id, handle.clone()) {
                        center.watch(id, &handle);
                        center.apply(id, Signal::MediaUp);
                    } else {
                        let _ = handle.terminate().await;
                    }
                }
                Err(error) => {
                    log::warn!("calls: could not answer the call");
                    center.apply(id, Signal::Failed(error.to_string()));
                }
            }
        });
    }

    // Either way

    /// Stores the handle of session `id`. `false` if the call ended meanwhile.
    fn attach(&self, id: u64, handle: CallHandle) -> bool {
        let mut call = lock(&self.call);
        match call
            .as_mut()
            .filter(|s| s.info.session == id && !s.info.phase.is_ended())
        {
            Some(session) => {
                session.wa_id = Some(handle.call_id().to_owned());
                session.handle = Some(handle);
                true
            }
            None => false,
        }
    }

    /// Ends the call when its media does, and logs what the engine reports.
    fn watch(self: &Arc<Self>, id: u64, handle: &CallHandle) {
        let ended = handle.clone();
        let center = self.clone();
        tokio::spawn(async move {
            ended.wait_ended().await;
            center.apply(id, Signal::MediaEnded);
        });
        let events = handle.events();
        tokio::spawn(async move {
            while let Ok(event) = events.recv().await {
                match event {
                    CallEvent::RelayAllocated => log::info!("calls: media path is up"),
                    CallEvent::RelayAllocateFailed(code) => {
                        log::warn!("calls: the relay refused the media path ({code})")
                    }
                    CallEvent::RelayAllocateTimedOut => {
                        log::warn!("calls: the relay did not answer")
                    }
                    CallEvent::MediaSetupFailed(_) => log::warn!("calls: media setup failed"),
                    CallEvent::AudioSilent {
                        dominant_reason, ..
                    } => log::warn!("calls: audio arrives but is silent ({dominant_reason:?})"),
                    CallEvent::AudioReceptionStalled { silent_for_ms } => {
                        log::warn!("calls: no audio for {silent_for_ms:?} ms")
                    }
                    CallEvent::AudioCodecSwitched { .. } => {
                        log::info!("calls: the other side's codec was corrected")
                    }
                    CallEvent::Closed(reason) => {
                        log::info!("calls: media closed ({reason:?})");
                        break;
                    }
                    _ => {}
                }
            }
        });
    }

    /// Hands the other side's audio to Swift until the call drops its sink.
    fn play(self: Arc<Self>, playout: async_channel::Receiver<Vec<i16>>) {
        tokio::spawn(async move {
            while let Ok(frame) = playout.recv().await {
                let listener = lock(&self.listener).clone();
                if let Some(listener) = listener {
                    listener.on_playout(frame);
                }
            }
        });
    }

    pub fn hang_up(self: &Arc<Self>) {
        let (id, offer) = {
            let call = lock(&self.call);
            let Some(session) = call.as_ref().filter(|s| !s.info.phase.is_ended()) else {
                return;
            };
            let offer = (session.info.phase == CallPhase::Ringing)
                .then(|| session.offer.clone())
                .flatten();
            (session.info.session, offer)
        };
        let handle = self.apply(id, Signal::LocalHangUp);
        let Some((client, runtime)) = self.client() else {
            return;
        };
        runtime.spawn(async move {
            if let Some(offer) = offer {
                if client.voip().reject(&offer).await.is_err() {
                    log::warn!("calls: could not decline the call");
                }
            } else if let Some(handle) = handle {
                let _ = handle.terminate().await;
            }
            // An outgoing call still sending its offer has no handle yet;
            // `place` terminates it when the handle arrives.
        });
    }

    pub fn set_muted(self: &Arc<Self>, muted: bool) {
        let (info, handle) = {
            let mut call = lock(&self.call);
            let Some(session) = call.as_mut().filter(|s| !s.info.phase.is_ended()) else {
                return;
            };
            session.info.muted = muted;
            (session.info.clone(), session.handle.clone())
        };
        self.publish(info);
        self.announce_muted(handle, muted);
    }

    fn announce_muted(&self, handle: Option<CallHandle>, muted: bool) {
        let (Some(handle), Some((_, runtime))) = (handle, self.client()) else {
            return;
        };
        runtime.spawn(async move {
            if handle.set_muted(muted).await.is_err() {
                log::warn!("calls: could not tell the other side about mute");
            }
        });
    }

    pub fn push_microphone(&self, samples: Vec<i16>) {
        let call = lock(&self.call);
        if let Some(microphone) = call.as_ref().and_then(|s| s.microphone.as_ref()) {
            // A full queue means the engine is not reading yet, or is behind:
            // the newest audio matters more than this frame.
            let _ = microphone.try_send(samples);
        }
    }

    // WhatsApp's events

    fn on_event(self: &Arc<Self>, event: &Event) {
        match event {
            Event::IncomingCall(call) => self.on_call_stanza(call),
            Event::CallEndedElsewhere(ended) => {
                if let Some(id) = self.session_for_wa_id(&ended.call_id) {
                    let signal = match ended.outcome {
                        ElsewhereOutcome::Accepted => Signal::AnsweredElsewhere,
                        _ => Signal::DeclinedElsewhere,
                    };
                    self.apply(id, signal);
                }
            }
            Event::MissedCall(_) => log::info!("calls: a call was missed while offline"),
            _ => {}
        }
    }

    fn on_call_stanza(self: &Arc<Self>, call: &IncomingCall) {
        let by_id = |center: &Self| center.session_for_wa_id(call.action.call_id());
        match &call.action {
            CallAction::Offer {
                is_video,
                group_jid,
                ..
            } => {
                if call.offline {
                    return;
                }
                if group_jid.is_some() {
                    log::info!("calls: group calls are left to the phone");
                    return;
                }
                let Some((client, runtime)) = self.client() else {
                    return;
                };
                let center = self.clone();
                let offer = call.clone();
                let video = *is_video;
                runtime.spawn(async move {
                    let chat = chat_of(&client, &offer).await;
                    center.ring(offer, chat, video);
                });
            }
            CallAction::Accept { .. } => {
                if let Some(id) = by_id(self) {
                    self.apply(id, Signal::PeerAccepted);
                    // Muting while it rang stayed local; say it now.
                    let (muted, handle) = {
                        let call = lock(&self.call);
                        let session = call.as_ref().filter(|s| s.info.session == id);
                        (
                            session.is_some_and(|s| s.info.muted),
                            session.and_then(|s| s.handle.clone()),
                        )
                    };
                    if muted {
                        self.announce_muted(handle, true);
                    }
                }
            }
            // A reason means one device could not take it; the others ring on.
            CallAction::Reject { reason: None, .. } => {
                if let Some(id) = by_id(self) {
                    self.apply(id, Signal::PeerRejected);
                }
            }
            CallAction::Terminate { reason, .. } => {
                if let Some(id) = by_id(self) {
                    let signal = match reason.as_deref() {
                        Some("accepted_elsewhere") => Signal::AnsweredElsewhere,
                        Some("rejected_elsewhere") => Signal::DeclinedElsewhere,
                        reason => Signal::PeerTerminated {
                            timeout: reason == Some("timeout"),
                        },
                    };
                    if let (Some(handle), Some((_, runtime))) =
                        (self.apply(id, signal), self.client())
                    {
                        // The library tears media down on a terminate; this
                        // only releases our side of a call it did not know.
                        runtime.spawn(async move { handle.hangup_local().await });
                    }
                }
            }
            _ => {}
        }
    }
}

/// The caller's chat id, by phone number when it is known, as upstream files
/// chats behind a privacy id.
async fn chat_of(client: &Client, offer: &IncomingCall) -> String {
    let CallAction::Offer {
        call_creator,
        caller_pn,
        ..
    } = &offer.action
    else {
        return offer.from.to_non_ad_string();
    };
    if let Some(pn) = caller_pn {
        return pn.to_non_ad_string();
    }
    if call_creator.is_lid()
        && let Ok(Some(entry)) = client.get_lid_pn_entry(call_creator).await
    {
        return format!("{}@s.whatsapp.net", entry.phone_number);
    }
    call_creator.to_non_ad_string()
}

fn describe(phase: &CallPhase) -> String {
    match phase {
        CallPhase::Ended { reason } => match reason {
            super::CallEndReason::Failed { .. } => "ended: failed".into(),
            other => format!("ended: {other:?}"),
        },
        other => format!("{other:?}"),
    }
}

/// Forwards WhatsApp's call events to the center while it exists.
struct CallEvents(Weak<Center>);

impl EventHandler for CallEvents {
    fn handle_event(&self, event: Arc<Event>) {
        if let Some(center) = self.0.upgrade() {
            center.on_event(&event);
        }
    }

    fn interest(&self) -> EventInterest {
        EventInterest::of(&[
            EventKind::IncomingCall,
            EventKind::MissedCall,
            EventKind::CallEndedElsewhere,
        ])
    }
}
