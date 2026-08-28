//! Utilities used to create and access data specific to Elixir structs. Keep in mind that an
//! Elixir struct is a normal Erlang map, and functions from the `map` module can be used.
//!
//! # Elixir struct transcoders
//! The compiler plugin has functionality for automatically generating a transcoder that can decode
//! and encode a Rust struct to an Elixir struct. To do so, simply annotate a struct with
//! `#[derive(NifStruct)]
//! `#[module = "Elixir.TheStructModule"]`.

use super::atom::{self, Atom};
use crate::wrapper::map;
use crate::{NifResult, Term};

pub fn get_ex_struct_name(map: Term) -> NifResult<Atom> {
    // In an Elixir struct the value in the __struct__ field is always an atom.
    map.map_get(atom::__struct__(), |res| res.and_then(Atom::from_term))
}

pub fn make_ex_struct<R>(
    struct_module: &str,
    closure: impl for<'a> FnOnce(NifResult<Term<'a>>) -> R,
) -> R {
    super::map::map_new(|map| {
        let struct_atom = atom::__struct__();
        let module_atom = Atom::from_str(map.get_env(), struct_module);
        let map = module_atom.and_then(|module_atom| {
            let env = map.get_env();
            unsafe {
                map::map_put(
                    env.as_c_arg(),
                    map.as_c_arg(),
                    struct_atom.as_c_arg(),
                    module_atom.as_c_arg(),
                )
                .map(|inner| Term::new(env, inner))
                .ok_or(crate::Error::BadArg)
            }
        });
        closure(map)
    })
}
