use std::ops::Deref;

use crate::{Decoder, Encoder, Env, Error, NifResult, Term};

use crate::sys::enif_make_ref;

/// Wrapper for BEAM reference terms.
#[derive(PartialEq, Eq, Clone, Copy)]
pub struct Reference<'a>(Term<'a>);

/// Create a new reference in the current thread-local environment.
pub fn make_ref<R>(closure: impl for<'a> FnOnce(Reference<'a>) -> R) -> R {
    Env::with_current(|env| closure(env.make_ref()))
}

impl Reference<'_> {
    /// Returns a representation of self in the current thread-local environment.
    pub fn in_env<R>(&self, closure: impl for<'b> FnOnce(Reference<'b>) -> R) -> R {
        self.0.in_current_env(|term| closure(Reference(term)))
    }

    /// Create a new reference in the current thread-local environment.
    pub fn current<R>(closure: impl for<'b> FnOnce(Reference<'b>) -> R) -> R {
        make_ref(closure)
    }
}

impl<'a> Deref for Reference<'a> {
    type Target = Term<'a>;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl<'a> From<Reference<'a>> for Term<'a> {
    fn from(term: Reference<'a>) -> Self {
        term.0
    }
}

impl<'a> TryFrom<Term<'a>> for Reference<'a> {
    type Error = Error;

    fn try_from(term: Term<'a>) -> Result<Self, Self::Error> {
        if term.is_ref() {
            Ok(Reference(term))
        } else {
            Err(Error::BadArg)
        }
    }
}

impl<'a> Decoder<'a> for Reference<'a> {
    fn decode(term: Term<'a>) -> NifResult<Self> {
        term.try_into()
    }
}

impl Encoder for Reference<'_> {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        self.0.encode(env)
    }
}

impl<'a> Env<'a> {
    /// Create a new reference in this environment
    pub fn make_ref(self) -> Reference<'a> {
        unsafe { Reference(Term::new(self, enif_make_ref(self.as_c_arg()))) }
    }
}
