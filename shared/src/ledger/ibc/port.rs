//! IBC validity predicate for port module

use std::str::FromStr;

use ibc::ics04_channel::context::ChannelReader;
use ibc::ics05_port::capabilities::Capability;
use ibc::ics05_port::context::PortReader;
use ibc::ics24_host::identifier::PortId;
use ibc::ics24_host::Path;
use thiserror::Error;

use super::{Ibc, StateChange};
use crate::ledger::storage::{self, StorageHasher};
use crate::types::storage::{Key, KeySeg};

#[allow(missing_docs)]
#[derive(Error, Debug)]
pub enum Error {
    #[error("Key error: {0}")]
    KeyError(String),
    #[error("State change error: {0}")]
    StateChangeError(String),
    #[error("Port error: {0}")]
    PortError(String),
    #[error("Capability error: {0}")]
    CapabilityError(String),
}

/// IBC port functions result
pub type Result<T> = std::result::Result<T, Error>;

impl<'a, DB, H> Ibc<'a, DB, H>
where
    DB: 'static + storage::DB + for<'iter> storage::DBIter<'iter>,
    H: 'static + StorageHasher,
{
    pub(super) fn validate_port(&self, key: &Key) -> Result<bool> {
        let port_id = Self::get_port_id(key)?;
        match self.get_port_state_change(&port_id)? {
            StateChange::Created => {
                match self.authenticated_capability(&port_id) {
                    Ok(_) => Ok(true),
                    Err(e) => Err(Error::PortError(format!(
                        "The port is not authenticated: ID {}, {}",
                        port_id, e
                    ))),
                }
            }
            _ => Err(Error::PortError(format!(
                "The state change of the port is invalid: Port {}",
                port_id
            ))),
        }
    }

    /// Returns the port ID after #IBC/channelEnds/ports
    pub(super) fn get_port_id(key: &Key) -> Result<PortId> {
        match key.segments.get(3) {
            Some(id) => PortId::from_str(&id.raw())
                .map_err(|e| Error::KeyError(e.to_string())),
            None => Err(Error::KeyError(format!(
                "The key doesn't have a port ID: Key {}",
                key
            ))),
        }
    }

    fn get_port_state_change(&self, port_id: &PortId) -> Result<StateChange> {
        let path = Path::Ports(port_id.clone()).to_string();
        let key =
            Key::ibc_key(path).expect("Creating a key for a connection failed");
        self.get_state_change(&key)
            .map_err(|e| Error::StateChangeError(e.to_string()))
    }

    pub(super) fn validate_capability(&self, key: &Key) -> Result<bool> {
        if key.is_ibc_capability_index() {
            Ok(self.capability_index_pre()? < self.capability_index()?)
        } else {
            match self
                .get_state_change(key)
                .map_err(|e| Error::StateChangeError(e.to_string()))?
            {
                StateChange::Created => {
                    let cap = Self::get_capability(key)?;
                    let port_id = self.get_port_by_capability(&cap)?;
                    match self.lookup_module_by_port(&port_id) {
                        Some(c) => Ok(c == cap),
                        None => Err(Error::CapabilityError(format!(
                            "The capability is not mapped: Index {}, Port {}",
                            cap.index(),
                            port_id
                        ))),
                    }
                }
                _ => Err(Error::StateChangeError(format!(
                    "The state change of the capability is invalid: key {}",
                    key
                ))),
            }
        }
    }

    fn capability_index_pre(&self) -> Result<u64> {
        let key = Key::ibc_capability_index();
        self.read_counter_pre(&key)
            .map_err(|e| Error::CapabilityError(e.to_string()))
    }

    fn capability_index(&self) -> Result<u64> {
        let key = Key::ibc_capability_index();
        Ok(self.read_counter(&key))
    }

    fn get_capability(key: &Key) -> Result<Capability> {
        // the capability index after #IBC/capabilities
        match key.segments.get(2) {
            Some(i) => {
                let index: u64 = i.raw().parse().map_err(|e| {
                    Error::CapabilityError(format!(
                        "The key has a non-number index: Key {}, {}",
                        key, e
                    ))
                })?;
                Ok(Capability::from(index))
            }
            None => Err(Error::CapabilityError(format!(
                "The key doesn't have a capability index: Key {}",
                key
            ))),
        }
    }

    fn get_port_by_capability(&self, cap: &Capability) -> Result<PortId> {
        let path = format!("capabilities/{}", cap.index());
        let key =
            Key::ibc_key(path).expect("Creating a key for a capability failed");
        match self.ctx.read_post(&key) {
            Ok(Some(value)) => {
                let id: String =
                    storage::types::decode(&value).map_err(|e| {
                        Error::PortError(format!(
                            "Decoding the port ID failed: {}",
                            e
                        ))
                    })?;
                PortId::from_str(&id)
                    .map_err(|e| Error::PortError(e.to_string()))
            }
            Ok(None) => Err(Error::PortError(
                "The capability is not mapped to any port".to_owned(),
            )),
            Err(e) => {
                Err(Error::PortError(format!("Reading the port failed {}", e)))
            }
        }
    }
}

impl<'a, DB, H> PortReader for Ibc<'a, DB, H>
where
    DB: 'static + storage::DB + for<'iter> storage::DBIter<'iter>,
    H: 'static + StorageHasher,
{
    fn lookup_module_by_port(&self, port_id: &PortId) -> Option<Capability> {
        let path = Path::Ports(port_id.clone()).to_string();
        let key = Key::ibc_key(path).expect("Creating a key for a port failed");
        match self.ctx.read_post(&key) {
            Ok(Some(value)) => {
                let index: u64 = match storage::types::decode(&value) {
                    Ok(i) => i,
                    Err(_) => return None,
                };
                Some(Capability::from(index))
            }
            _ => None,
        }
    }

    fn authenticate(&self, cap: &Capability, port_id: &PortId) -> bool {
        match self.get_port_by_capability(cap) {
            Ok(p) => p == *port_id,
            Err(_) => false,
        }
    }
}
