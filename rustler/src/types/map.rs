//! Utilities used to access and create Erlang maps.

use super::atom;
use crate::wrapper::map;
use crate::{Decoder, Encoder, Env, Error, NifResult, Term};
use std::ops::RangeInclusive;

#[inline]
pub(crate) fn map_new_in_env(env: Env) -> Term {
    unsafe { Term::new(env, map::map_new(env.as_c_arg())) }
}

#[inline]
pub fn map_new<R>(closure: impl for<'a> FnOnce(Term<'a>) -> R) -> R {
    Env::with_current(|env| closure(map_new_in_env(env)))
}

#[inline]
pub fn map_from_arrays<R>(
    keys: &[impl Encoder],
    values: &[impl Encoder],
    closure: impl for<'a> FnOnce(NifResult<Term<'a>>) -> R,
) -> R {
    Env::with_current(|env| {
        if keys.len() == values.len() {
            let keys: Vec<_> = keys.iter().map(|k| k.encode(env).as_c_arg()).collect();
            let values: Vec<_> = values.iter().map(|v| v.encode(env).as_c_arg()).collect();

            unsafe {
                closure(
                    map::make_map_from_arrays(env.as_c_arg(), &keys, &values)
                        .map_or_else(|| Err(Error::BadArg), |map| Ok(Term::new(env, map))),
                )
            }
        } else {
            closure(Err(Error::BadArg))
        }
    })
}

#[inline]
pub fn map_from_pairs<R>(
    pairs: &[(impl Encoder, impl Encoder)],
    closure: impl for<'a> FnOnce(NifResult<Term<'a>>) -> R,
) -> R {
    Env::with_current(|env| {
        let (keys, values): (Vec<_>, Vec<_>) = pairs
            .iter()
            .map(|(k, v)| (k.encode(env).as_c_arg(), v.encode(env).as_c_arg()))
            .unzip();

        unsafe {
            closure(
                map::make_map_from_arrays(env.as_c_arg(), &keys, &values)
                    .map_or_else(|| Err(Error::BadArg), |map| Ok(Term::new(env, map))),
            )
        }
    })
}

#[inline]
pub fn map_from_term_arrays<R>(
    keys: &[Term],
    values: &[Term],
    closure: impl for<'a> FnOnce(NifResult<Term<'a>>) -> R,
) -> R {
    Env::with_current(|env| {
        if keys.len() == values.len() {
            let keys: Vec<_> = keys.iter().map(|k| k.in_env(env).as_c_arg()).collect();
            let values: Vec<_> = values.iter().map(|v| v.in_env(env).as_c_arg()).collect();

            unsafe {
                closure(
                    map::make_map_from_arrays(env.as_c_arg(), &keys, &values)
                        .map_or_else(|| Err(Error::BadArg), |map| Ok(Term::new(env, map))),
                )
            }
        } else {
            closure(Err(Error::BadArg))
        }
    })
}

#[inline]
pub(crate) fn map_from_arrays_in_env<'a>(
    env: Env<'a>,
    keys: &[impl Encoder],
    values: &[impl Encoder],
) -> NifResult<Term<'a>> {
    if keys.len() == values.len() {
        let keys: Vec<_> = keys.iter().map(|k| k.encode(env).as_c_arg()).collect();
        let values: Vec<_> = values.iter().map(|v| v.encode(env).as_c_arg()).collect();

        unsafe {
            map::make_map_from_arrays(env.as_c_arg(), &keys, &values)
                .map_or_else(|| Err(Error::BadArg), |map| Ok(Term::new(env, map)))
        }
    } else {
        Err(Error::BadArg)
    }
}

#[inline]
pub(crate) fn map_get<'a>(env: Env<'a>, map: Term<'a>, key: impl Encoder) -> NifResult<Term<'a>> {
    match unsafe { map::get_map_value(env.as_c_arg(), map.as_c_arg(), key.encode(env).as_c_arg()) }
    {
        Some(value) => Ok(unsafe { Term::new(env, value) }),
        None => Err(Error::BadArg),
    }
}

/// ## Map terms
impl<'a> Term<'a> {
    /// Constructs a new, empty map term in the current thread-local environment.
    #[inline]
    pub fn map_new<R>(closure: impl for<'b> FnOnce(Term<'b>) -> R) -> R {
        super::map::map_new(closure)
    }

    /// Construct a new map from two vectors in the current thread-local
    /// environment.
    #[inline]
    pub fn map_from_arrays<R>(
        keys: &[impl Encoder],
        values: &[impl Encoder],
        closure: impl for<'b> FnOnce(NifResult<Term<'b>>) -> R,
    ) -> R {
        super::map::map_from_arrays(keys, values, closure)
    }

    /// Construct a new map from two vectors of terms.
    ///
    /// It is identical to map_from_arrays, but requires the keys and values to
    /// be encoded already - this is useful for constructing maps whose values
    /// or keys are different Rust types, with the same performance as map_from_arrays.
    pub fn map_from_term_arrays_in_env(
        env: Env<'a>,
        keys: &[Term<'a>],
        values: &[Term<'a>],
    ) -> NifResult<Term<'a>> {
        if keys.len() == values.len() {
            let keys: Vec<_> = keys.iter().map(|k| k.as_c_arg()).collect();
            let values: Vec<_> = values.iter().map(|v| v.as_c_arg()).collect();

            unsafe {
                map::make_map_from_arrays(env.as_c_arg(), &keys, &values)
                    .map_or_else(|| Err(Error::BadArg), |map| Ok(Term::new(env, map)))
            }
        } else {
            Err(Error::BadArg)
        }
    }

    /// Construct a new map from two vectors of terms in the current
    /// thread-local environment.
    pub fn map_from_term_arrays<R>(
        keys: &[Term],
        values: &[Term],
        closure: impl for<'b> FnOnce(NifResult<Term<'b>>) -> R,
    ) -> R {
        super::map::map_from_term_arrays(keys, values, closure)
    }

    /// Construct a new map from pairs in the current thread-local environment.
    #[inline]
    pub fn map_from_pairs<R>(
        pairs: &[(impl Encoder, impl Encoder)],
        closure: impl for<'b> FnOnce(NifResult<Term<'b>>) -> R,
    ) -> R {
        super::map::map_from_pairs(pairs, closure)
    }

    /// Gets the value corresponding to a key in a map term using the current
    /// thread-local environment.
    #[inline]
    pub fn map_get<R>(self, key: impl Encoder, closure: impl for<'b> FnOnce(NifResult<Term<'b>>) -> R) -> R {
        Env::with_current(|env| {
            match unsafe {
                map::get_map_value(env.as_c_arg(), self.in_env(env).as_c_arg(), key.encode(env).as_c_arg())
            } {
                Some(value) => closure(Ok(unsafe { Term::new(env, value) })),
                None => closure(Err(Error::BadArg)),
            }
        })
    }

    /// Gets the value corresponding to a key in a map term using this term's
    /// environment.
    #[inline]
    pub fn map_get_in_env(self, key: impl Encoder) -> NifResult<Term<'a>> {
        super::map::map_get(self.get_env(), self, key)
    }

    /// Gets the size of a map term using the current thread-local environment.
    #[inline]
    pub fn map_size(self) -> NifResult<usize> {
        Env::with_current(|env| unsafe { map::get_map_size(env.as_c_arg(), self.in_env(env).as_c_arg()).ok_or(Error::BadArg) })
    }

    /// Makes a copy of the self map term and sets key to value using the
    /// current thread-local environment.
    #[inline]
    pub fn map_put<R>(
        self,
        key: impl Encoder,
        value: impl Encoder,
        closure: impl for<'b> FnOnce(NifResult<Term<'b>>) -> R,
    ) -> R {
        Env::with_current(|env| {
            match unsafe {
                map::map_put(
                    env.as_c_arg(),
                    self.in_env(env).as_c_arg(),
                    key.encode(env).as_c_arg(),
                    value.encode(env).as_c_arg(),
                )
            } {
                Some(inner) => closure(Ok(unsafe { Term::new(env, inner) })),
                None => closure(Err(Error::BadArg)),
            }
        })
    }

    /// Makes a copy of the self map term and removes key using the current
    /// thread-local environment.
    #[inline]
    pub fn map_remove<R>(
        self,
        key: impl Encoder,
        closure: impl for<'b> FnOnce(NifResult<Term<'b>>) -> R,
    ) -> R {
        Env::with_current(|env| {
            match unsafe {
                map::map_remove(env.as_c_arg(), self.in_env(env).as_c_arg(), key.encode(env).as_c_arg())
            } {
                Some(inner) => closure(Ok(unsafe { Term::new(env, inner) })),
                None => closure(Err(Error::BadArg)),
            }
        })
    }

    /// Makes a copy of the self map term where key is set to value.
    ///
    /// Returns Err(Error::BadArg) if the term is not a map of if key
    /// doesn't exist.
    /// Makes a copy of the self map term where key is set to value using the
    /// current thread-local environment.
    #[inline]
    pub fn map_update<R>(
        self,
        key: impl Encoder,
        new_value: impl Encoder,
        closure: impl for<'b> FnOnce(NifResult<Term<'b>>) -> R,
    ) -> R {
        Env::with_current(|env| {
            match unsafe {
                map::map_update(
                    env.as_c_arg(),
                    self.in_env(env).as_c_arg(),
                    key.encode(env).as_c_arg(),
                    new_value.encode(env).as_c_arg(),
                )
            } {
                Some(inner) => closure(Ok(unsafe { Term::new(env, inner) })),
                None => closure(Err(Error::BadArg)),
            }
        })
    }
}

struct SimpleMapIterator<'a> {
    map: Term<'a>,
    entry: map::MapIteratorEntry,
    iter: Option<map::ErlNifMapIterator>,
    last_key: Option<Term<'a>>,
    done: bool,
}

impl<'a> SimpleMapIterator<'a> {
    fn next(&mut self) -> Option<(Term<'a>, Term<'a>)> {
        if self.done {
            return None;
        }

        let iter = loop {
            match self.iter.as_mut() {
                None => {
                    match unsafe {
                        map::map_iterator_create(
                            self.map.get_env().as_c_arg(),
                            self.map.as_c_arg(),
                            self.entry,
                        )
                    } {
                        Some(iter) => {
                            self.iter = Some(iter);
                            continue;
                        }
                        None => {
                            self.done = true;
                            return None;
                        }
                    }
                }
                Some(iter) => {
                    break iter;
                }
            }
        };

        let env = self.map.get_env();

        unsafe {
            match map::map_iterator_get_pair(env.as_c_arg(), iter) {
                Some((key, value)) => {
                    match self.entry {
                        map::MapIteratorEntry::First => {
                            map::map_iterator_next(env.as_c_arg(), iter);
                        }
                        map::MapIteratorEntry::Last => {
                            map::map_iterator_prev(env.as_c_arg(), iter);
                        }
                    }
                    let key = Term::new(env, key);
                    self.last_key = Some(key);
                    Some((key, Term::new(env, value)))
                }
                None => {
                    self.done = true;
                    None
                }
            }
        }
    }
}

impl Drop for SimpleMapIterator<'_> {
    fn drop(&mut self) {
        if let Some(iter) = self.iter.as_mut() {
            unsafe {
                map::map_iterator_destroy(self.map.get_env().as_c_arg(), iter);
            }
        }
    }
}

pub struct MapIterator<'a> {
    forward: SimpleMapIterator<'a>,
    reverse: SimpleMapIterator<'a>,
}

impl<'a> MapIterator<'a> {
    pub fn new(map: Term<'a>) -> Option<MapIterator<'a>> {
        if map.is_map() {
            Some(MapIterator {
                forward: SimpleMapIterator {
                    map,
                    entry: map::MapIteratorEntry::First,
                    iter: None,
                    last_key: None,
                    done: false,
                },
                reverse: SimpleMapIterator {
                    map,
                    entry: map::MapIteratorEntry::Last,
                    iter: None,
                    last_key: None,
                    done: false,
                },
            })
        } else {
            None
        }
    }
}

impl<'a> Iterator for MapIterator<'a> {
    type Item = (Term<'a>, Term<'a>);

    fn next(&mut self) -> Option<Self::Item> {
        self.forward.next().and_then(|(key, value)| {
            if self.reverse.last_key == Some(key) {
                self.forward.done = true;
                self.reverse.done = true;
                return None;
            }
            Some((key, value))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::OwnedEnv;

    #[test]
    #[ignore = "requires initialized NIF runtime callbacks"]
    fn map_new_current_creates_map() {
        Term::map_new(|map| {
            assert!(map.is_map());
            assert_eq!(map.map_size().unwrap(), 0);
        });
    }

    #[test]
    #[ignore = "requires initialized NIF runtime callbacks"]
    fn map_from_arrays_current_builds_map() {
        let keys = ["alpha", "beta"];
        let values = [1_i64, 2_i64];

        Term::map_from_arrays(&keys, &values, |res| {
            let map = res.unwrap();
            assert!(map.is_map());
            assert_eq!(map.map_size().unwrap(), 2);
            assert_eq!(
                map.map_get("alpha", |res| res.and_then(|term| term.decode::<i64>()).unwrap()),
                1
            );
            assert_eq!(
                map.map_get("beta", |res| res.and_then(|term| term.decode::<i64>()).unwrap()),
                2
            );
        });
    }

    #[test]
    #[ignore = "requires initialized NIF runtime callbacks"]
    fn map_from_term_arrays_current_copies_terms_between_envs() {
        let env = OwnedEnv::new();
        let saved_key = env.save("key");
        let saved_value = env.save(123_i64);

        env.run(|env| {
            let key = saved_key.load(env);
            let value = saved_value.load(env);

            Term::map_from_term_arrays(&[key], &[value], |res| {
                let map = res.unwrap();
                assert!(map.is_map());
                assert_eq!(map.map_get("key", |res| res.and_then(|term| term.decode::<i64>()).unwrap()), 123);
            });
        });
    }
}

impl DoubleEndedIterator for MapIterator<'_> {
    fn next_back(&mut self) -> Option<Self::Item> {
        self.reverse.next().and_then(|(key, value)| {
            if self.forward.last_key == Some(key) {
                self.forward.done = true;
                self.reverse.done = true;
                return None;
            }
            Some((key, value))
        })
    }
}

impl<'a> Decoder<'a> for MapIterator<'a> {
    fn decode(term: Term<'a>) -> NifResult<Self> {
        match MapIterator::new(term) {
            Some(iter) => Ok(iter),
            None => Err(Error::BadArg),
        }
    }
}

impl<'a, T> Decoder<'a> for RangeInclusive<T>
where
    T: Decoder<'a>,
{
    fn decode(term: Term<'a>) -> NifResult<Self> {
        let env = term.get_env();
        let name = map_get(env, term, atom::__struct__())?.decode::<crate::Atom>()?;

        if name != crate::Atom::from_str(env, "Elixir.Range")? {
            return Err(Error::BadArg);
        }

        let first = map_get(env, term, atom::first())?.decode::<T>()?;
        let last = map_get(env, term, atom::last())?.decode::<T>()?;
        if let Ok(step) = map_get(env, term, atom::step()) {
            match step.decode::<i64>()? {
                1 => (),
                _ => return Err(Error::BadArg),
            }
        }

        Ok(first..=last)
    }
}
