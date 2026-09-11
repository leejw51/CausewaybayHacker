//! Getting to AUTHENTICATED, and getting back there after a drop.
//!
//! PROTOCOL §3.1: a connection starts ANONYMOUS and accepts exactly four
//! messages; everything else is `unauthorized`. §6 is the reconnection rule.
//! Both live here so no command has to remember either.

use crate::client::Conn;
use crate::error::{Code, Error, Result};
use crate::proto::{AuthOk, Challenge, User};
use crate::store::{self, Store};
use crate::wallet::Keypair;

pub struct Session {
    pub conn: Conn,
    pub user: User,
    pub server: String,
    token: String,
}

impl Session {
    /// Log in from key material. The key is borrowed, used for exactly one
    /// signature, and never stored — §3.1's *"the only thing that crosses the
    /// wire is a signature"* is a property of this function.
    pub async fn login(
        store: &Store,
        server: &str,
        key: &Keypair,
        name: Option<&str>,
        trace: bool,
    ) -> Result<Session> {
        let mut conn = Conn::connect_with_backoff(server, Some(4), |attempt, delay| {
            eprintln!(
                "  no answer from {server}; retry {attempt} in {:.1}s",
                delay.as_secs_f64()
            );
        })
        .await?;
        conn.trace = trace;

        let address = key.address();
        let challenge: Challenge = conn
            .call("auth.challenge", serde_json::json!({ "address": address }))
            .await?;

        // §4.2: "Sign `message` byte-for-byte as given. Do not reconstruct it
        // from the parts." Nothing here parses the message, splits it, or
        // rebuilds it — the bytes the server sent are the bytes that are
        // hashed.
        let signature = key.sign_message_hex(challenge.message.as_bytes())?;

        let mut payload = serde_json::json!({
            "address": address,
            "signature": signature,
        });
        // §4.3: `name` is optional and only used when the user is created.
        if let Some(name) = name {
            payload["name"] = serde_json::Value::String(name.to_string());
        }
        let auth: AuthOk = conn.call("auth.login", payload).await?;

        let record = store::Session {
            server: server.to_string(),
            token: auth.token.clone(),
            address: auth.user.address.clone(),
            name: auth.user.name.clone(),
        };
        store.save_session(&record)?;
        store.set_server(server)?;

        Ok(Session {
            conn,
            user: auth.user,
            server: server.to_string(),
            token: auth.token,
        })
    }

    /// Open a connection and resume with the stored token.
    ///
    /// §4.4: *"The returned token may differ from the one sent — the server
    /// rotates on use. Store the returned one."* That is §8.7, and it is done
    /// here, once, for every command.
    pub async fn resume(store: &Store, server: &str, trace: bool) -> Result<Session> {
        let state = store.load()?;
        let stored = state.session(server).cloned().ok_or_else(|| {
            Error::new(
                Code::Unauthorized,
                format!("no session for {server}; run `cwbh login`"),
            )
        })?;

        let mut conn = Conn::connect_with_backoff(server, Some(4), |attempt, delay| {
            eprintln!(
                "  no answer from {server}; retry {attempt} in {:.1}s",
                delay.as_secs_f64()
            );
        })
        .await?;
        conn.trace = trace;
        Session::resume_on(conn, store, server, &stored.token).await
    }

    /// The same trade, on a connection somebody else opened — what a
    /// reconnect uses.
    pub async fn resume_on(
        mut conn: Conn,
        store: &Store,
        server: &str,
        token: &str,
    ) -> Result<Session> {
        let auth: AuthOk = match conn
            .call("auth.resume", serde_json::json!({ "token": token }))
            .await
        {
            Ok(auth) => auth,
            Err(e) if *e.code.effective() == Code::Unauthorized => {
                // §6.4: an expired or unknown token means the login screen.
                // Forgetting it is a record, not an edit (SPEC §1.1).
                store.clear_session(server)?;
                return Err(Error::new(
                    Code::Unauthorized,
                    format!("the session for {server} has expired; run `cwbh login`"),
                ));
            }
            Err(e) => return Err(e),
        };

        store.save_session(&store::Session {
            server: server.to_string(),
            token: auth.token.clone(),
            address: auth.user.address.clone(),
            name: auth.user.name.clone(),
        })?;

        Ok(Session {
            conn,
            user: auth.user,
            server: server.to_string(),
            token: auth.token,
        })
    }

    /// §6: reconnect with backoff, resume with the stored token, and let the
    /// caller refetch whatever screen it is on. The token used is the one in
    /// memory, which is the one the last resume returned.
    pub async fn reconnect(
        &mut self,
        store: &Store,
        mut on_retry: impl FnMut(u32, std::time::Duration),
    ) -> Result<()> {
        let trace = self.conn.trace;
        let conn = Conn::connect_with_backoff(&self.server, None, &mut on_retry).await?;
        let mut conn = conn;
        conn.trace = trace;
        let resumed = Session::resume_on(conn, store, &self.server, &self.token).await?;
        self.conn = resumed.conn;
        self.user = resumed.user;
        self.token = resumed.token;
        Ok(())
    }

    /// The address the player is, lowercased — SPEC §3.4, and what names the
    /// work directory.
    pub fn address_lower(&self) -> String {
        self.user.address.to_lowercase()
    }

    pub async fn close(&mut self) {
        self.conn.close().await;
    }
}
