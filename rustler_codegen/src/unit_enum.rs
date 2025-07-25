use proc_macro2::{Span, TokenStream};
use quote::{quote, quote_spanned};

use heck::ToSnakeCase;
use syn::{self, spanned::Spanned, Fields, Ident, Variant};

use super::context::Context;

pub fn transcoder_decorator(ast: &syn::DeriveInput) -> TokenStream {
    let ctx = Context::from_ast(ast);

    let variants = ctx
        .variants
        .as_ref()
        .expect("NifUnitEnum can only be used with enums");

    for variant in variants {
        if let Fields::Unit = variant.fields {
        } else {
            return quote_spanned! { variant.span() =>
                compile_error!("NifUnitEnum can only be used with enums containing unit variants.");
            };
        }
    }

    let atoms: Vec<TokenStream> = variants
        .iter()
        .map(|variant| {
            let atom_str = variant.ident.to_string().to_snake_case();
            let atom_fn = Ident::new(&format!("atom_{atom_str}"), Span::call_site());
            quote! {
                #atom_fn = #atom_str,
            }
        })
        .collect();

    let atom_defs = quote! {
        rustler::atoms! {
            #(#atoms)*
        }
    };

    let atoms_module_name = ctx.atoms_module_name(Span::call_site());

    let decoder = if ctx.decode() {
        gen_decoder(&ctx, variants, &atoms_module_name)
    } else {
        quote! {}
    };

    let encoder = if ctx.encode() {
        gen_encoder(&ctx, variants, &atoms_module_name)
    } else {
        quote! {}
    };

    let gen = quote! {
        #[allow(non_snake_case)]
        mod #atoms_module_name {
            #atom_defs
        }

        #decoder
        #encoder
    };

    gen
}

fn gen_decoder(ctx: &Context, variants: &[&Variant], atoms_module_name: &Ident) -> TokenStream {
    let enum_name = ctx.ident;

    let variant_defs: Vec<TokenStream> = variants
        .iter()
        .map(|variant| {
            let variant_ident = &variant.ident;
            let atom_str = variant_ident.to_string().to_snake_case();
            let atom_fn = Ident::new(&format!("atom_{atom_str}"), Span::call_site());

            quote! {
                if value == #atom_fn() {
                    return Ok ( #enum_name :: #variant_ident );
                }
            }
        })
        .collect();

    super::encode_decode_templates::decoder(
        ctx,
        quote! {
            use #atoms_module_name::*;

            let value = ::rustler::types::atom::Atom::from_term(term)?;

            #(#variant_defs)*

            Err(::rustler::Error::RaiseAtom("invalid_variant"))
        },
    )
}

fn gen_encoder(ctx: &Context, variants: &[&Variant], atoms_module_name: &Ident) -> TokenStream {
    let enum_name = ctx.ident;

    let variant_defs: Vec<TokenStream> = variants
        .iter()
        .map(|variant| {
            let variant_ident = &variant.ident;
            let atom_str = variant_ident.to_string().to_snake_case();
            let atom_fn = Ident::new(&format!("atom_{atom_str}"), Span::call_site());

            quote! {
                #enum_name :: #variant_ident => ::rustler::Encoder::encode(&#atom_fn(), env),
            }
        })
        .collect();

    super::encode_decode_templates::encoder(
        ctx,
        quote! {
            use #atoms_module_name::*;

            match *self {
                #(#variant_defs)*
            }
        },
    )
}
