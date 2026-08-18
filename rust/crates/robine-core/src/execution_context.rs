use std::collections::BTreeSet;

use thiserror::Error;
use uuid::Uuid;

/// Request metadata and authorization scope passed to every use case.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionContext {
    pub actor: Actor,
    pub tenant_id: String,
    pub capabilities: BTreeSet<Capability>,
    pub correlation_id: Uuid,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Actor {
    pub id: String,
    pub kind: ActorKind,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum ActorKind {
    User,
    Runner,
    System,
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct Capability(String);

impl Capability {
    #[must_use]
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum ContextError {
    #[error("tenant ID must not be empty")]
    MissingTenant,
    #[error("at least one capability is required")]
    MissingCapabilities,
}

impl ExecutionContext {
    /// Builds the mandatory authorization scope for an embedded caller.
    ///
    /// # Errors
    ///
    /// Returns [`ContextError::MissingTenant`] when the tenant is blank and
    /// [`ContextError::MissingCapabilities`] when no capability was supplied.
    pub fn embedded(
        actor: Actor,
        tenant_id: impl Into<String>,
        capabilities: impl IntoIterator<Item = Capability>,
        correlation_id: Uuid,
    ) -> Result<Self, ContextError> {
        let tenant_id = tenant_id.into();
        let capabilities = capabilities.into_iter().collect::<BTreeSet<_>>();

        if tenant_id.trim().is_empty() {
            return Err(ContextError::MissingTenant);
        }
        if capabilities.is_empty() {
            return Err(ContextError::MissingCapabilities);
        }

        Ok(Self {
            actor,
            tenant_id,
            capabilities,
            correlation_id,
        })
    }

    #[must_use]
    pub fn permits(&self, capability: &str) -> bool {
        self.capabilities
            .iter()
            .any(|candidate| candidate.as_str() == capability)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn actor() -> Actor {
        Actor {
            id: "host-user-1".into(),
            kind: ActorKind::User,
        }
    }

    #[test]
    fn embedded_context_requires_a_tenant() {
        assert_eq!(
            ExecutionContext::embedded(
                actor(),
                " ",
                [Capability::new("pipelines:read")],
                Uuid::nil()
            ),
            Err(ContextError::MissingTenant)
        );
    }

    #[test]
    fn embedded_context_requires_capabilities() {
        assert_eq!(
            ExecutionContext::embedded(actor(), "tenant-1", [], Uuid::nil()),
            Err(ContextError::MissingCapabilities)
        );
    }

    #[test]
    fn context_checks_exact_capabilities() {
        let context = ExecutionContext::embedded(
            actor(),
            "tenant-1",
            [Capability::new("pipelines:read")],
            Uuid::nil(),
        )
        .expect("valid context");

        assert!(context.permits("pipelines:read"));
        assert!(!context.permits("pipelines:write"));
    }
}
