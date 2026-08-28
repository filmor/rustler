//! Utilities used for working with erlang linked lists.
//!
//! Right now the only supported way to read lists are through the ListIterator.

use crate::wrapper::{list, NIF_TERM};
use crate::{Decoder, Encoder, Env, Error, NifResult, Term};

/// Enables iteration over the items in the list.
///
/// Although this behaves like a standard Rust iterator
/// ([book](https://doc.rust-lang.org/book/iterators.html) /
/// [docs](https://doc.rust-lang.org/std/iter/trait.Iterator.html)), there are a couple of tricky
/// parts to using it.
///
/// Because the iterator is an iterator over `Term`s, you need to decode the terms before you
/// can do anything with them.
///
/// ## Example
/// An easy way to decode all terms in a list, is to use the `.map()` function of the iterator, and
/// decode every entry in the list. This will produce an iterator of `Result`s, and will therefore
/// not be directly usable in the way you might immediately expect.
///
/// For this case, the the `.collect()` function of rust iterators is useful, as it can lift
/// the `Result`s out of the list. (Contains extra type annotations for clarity)
///
/// ```
/// # use rustler::{Term, NifResult};
/// # use rustler::types::list::ListIterator;
/// # fn list_iterator_example(list_term: Term) -> NifResult<Vec<i64>> {
/// let list_iterator: ListIterator = list_term.decode()?;
///
/// let result: NifResult<Vec<i64>> = list_iterator
///     // Produces an iterator of NifResult<i64>
///     .map(|x| x.decode::<i64>())
///     // Lifts each value out of the result. Returns Ok(Vec<i64>) if successful, the first error
///     // Error(Error) on failure.
///     .collect::<NifResult<Vec<i64>>>();
/// # result
/// # }
/// ```
pub struct ListIterator<'a> {
    term: Term<'a>,
}

impl<'a> ListIterator<'a> {
    fn new(term: Term<'a>) -> Option<Self> {
        if term.is_list() {
            let iter = ListIterator { term };
            Some(iter)
        } else {
            None
        }
    }
}

impl<'a> Iterator for ListIterator<'a> {
    type Item = Term<'a>;

    #[inline]
    fn next(&mut self) -> Option<Term<'a>> {
        let env = self.term.get_env();
        let cell = unsafe { list::get_list_cell(env.as_c_arg(), self.term.as_c_arg()) };

        match cell {
            Some((head, tail)) => unsafe {
                self.term = Term::new(self.term.get_env(), tail);
                Some(Term::new(self.term.get_env(), head))
            },
            None => {
                if self.term.is_empty_list() {
                    // We reached the end of the list, finish the iterator.
                    None
                } else {
                    panic!("list iterator found improper list")
                }
            }
        }
    }
}

impl<'a> Decoder<'a> for ListIterator<'a> {
    #[inline]
    fn decode(term: Term<'a>) -> NifResult<Self> {
        match ListIterator::new(term) {
            Some(iter) => Ok(iter),
            None => Err(Error::BadArg),
        }
    }
}

//impl<'a, T> Encoder for Iterator<Item = T> where T: Encoder {
//    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
//        let term_arr: Vec<NIF_TERM> =
//            self.map(|x| x.encode(env).as_c_arg()).collect();
//    }
//}
impl<T> Encoder for Vec<T>
where
    T: Encoder,
{
    #[inline]
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        self.as_slice().encode(env)
    }
}

impl<'a, T> Decoder<'a> for Vec<T>
where
    T: Decoder<'a>,
{
    #[inline]
    fn decode(term: Term<'a>) -> NifResult<Self> {
        let iter: ListIterator = term.decode()?;
        let res: NifResult<Self> = iter.map(|x| x.decode::<T>()).collect();
        res
    }
}

impl<T> Encoder for [T]
where
    T: Encoder,
{
    #[inline]
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        let term_array: Vec<NIF_TERM> = self.iter().map(|x| x.encode(env).as_c_arg()).collect();
        unsafe { Term::new(env, list::make_list(env.as_c_arg(), &term_array)) }
    }
}

impl<T> Encoder for &[T]
where
    T: Encoder,
{
    #[inline]
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        let term_array: Vec<NIF_TERM> = self.iter().map(|x| x.encode(env).as_c_arg()).collect();
        unsafe { Term::new(env, list::make_list(env.as_c_arg(), &term_array)) }
    }
}

/// ## List terms
impl<'a> Term<'a> {
    /// Returns a new empty list in the current thread-local environment.
    #[inline]
    pub fn list_new_empty<R>(closure: impl for<'b> FnOnce(Term<'b>) -> R) -> R {
        Env::with_current(|env| {
            let list: &[u8] = &[];
            closure(list.encode(env))
        })
    }

    /// Returns an iterator over a list term.
    /// See documentation for ListIterator for more information.
    ///
    /// Returns None if the term is not a list.
    #[inline]
    pub fn into_list_iterator(self) -> NifResult<ListIterator<'a>> {
        ListIterator::new(self).ok_or(Error::BadArg)
    }

    /// Returns the length of a list term using the current thread-local
    /// environment.
    #[inline]
    pub fn list_length(self) -> NifResult<usize> {
        Env::with_current(|env| unsafe {
            list::get_list_length(env.as_c_arg(), self.in_env(env).as_c_arg()).ok_or(Error::BadArg)
        })
    }

    /// Unpacks a single cell at the head of a list term using the current
    /// thread-local environment.
    #[inline]
    pub fn list_get_cell<R>(
        self,
        closure: impl for<'b> FnOnce(NifResult<(Term<'b>, Term<'b>)>) -> R,
    ) -> R {
        Env::with_current(|env| unsafe {
            match list::get_list_cell(env.as_c_arg(), self.in_env(env).as_c_arg()) {
                Some((head, tail)) => closure(Ok((Term::new(env, head), Term::new(env, tail)))),
                None => closure(Err(Error::BadArg)),
            }
        })
    }

    /// Makes a copy of the self list term and reverses it using the current
    /// thread-local environment.
    #[inline]
    pub fn list_reverse<R>(self, closure: impl for<'b> FnOnce(NifResult<Term<'b>>) -> R) -> R {
        Env::with_current(|env| unsafe {
            match list::make_reverse_list(env.as_c_arg(), self.in_env(env).as_c_arg()) {
                Some(term) => closure(Ok(Term::new(env, term))),
                None => closure(Err(Error::BadArg)),
            }
        })
    }

    /// Adds `head` in a list cell with `self` as tail using the current
    /// thread-local environment.
    #[inline]
    pub fn list_prepend<R>(
        self,
        head: impl Encoder,
        closure: impl for<'b> FnOnce(Term<'b>) -> R,
    ) -> R {
        Env::with_current(|env| {
            let head = head.encode(env);
            unsafe {
                let term = list::make_list_cell(env.as_c_arg(), head.as_c_arg(), self.in_env(env).as_c_arg());
                closure(Term::new(env, term))
            }
        })
    }
}
