use super::traits::{self, is_monitor_resource};
use super::util::align_alloced_mem_for_struct;
use crate::{Env, LocalPid, Monitor, MonitorResource, Resource};
use rustler_sys::{
    c_char, c_void, ErlNifEnv, ErlNifMonitor, ErlNifPid, ErlNifResourceDown, ErlNifResourceDtor,
    ErlNifResourceFlags, ErlNifResourceType, ErlNifResourceTypeInit,
};
use std::any::TypeId;
use std::ffi::CString;
use std::mem::MaybeUninit;
use std::ptr;

#[derive(Debug)]
pub struct ResourceRegistration {
    get_type_id: fn() -> TypeId,
    get_type_name: fn() -> &'static str,
    init: ErlNifResourceTypeInit,
}

unsafe impl Sync for ResourceRegistration {}
inventory::collect!(ResourceRegistration);

impl ResourceRegistration {
    pub const fn new<T: Resource>() -> Self {
        let init = ErlNifResourceTypeInit {
            dtor: resource_destructor::<T> as *const ErlNifResourceDtor,
            stop: ptr::null(),
            down: ptr::null(),
            members: 1,
            dyncall: ptr::null(),
        };
        let res = Self {
            init,
            get_type_name: std::any::type_name::<T>,
            get_type_id: TypeId::of::<T>,
        };

        if is_monitor_resource::<T> {
            res.add_down_callback()
        } else {
            res
        }
    }

    pub fn add_down_callback<T: ?Sized>() -> bool {
        use std::cell::Cell;
        use std::marker::PhantomData;

        struct IsMonitorResource<'a, T: ?Sized> {
            is_monitor_resource: &'a Cell<bool>,
            _marker: PhantomData<T>,
        }
        impl<T: ?Sized> Clone for IsMonitorResource<'_, T> {
            fn clone(&self) -> Self {
                self.is_monitor_resource.set(false);
                Self {
                    is_monitor_resource: self.is_monitor_resource,
                    _marker: PhantomData,
                }
            }
        }
        impl<T: ?Sized + MonitorResource> Copy for IsMonitorResource<'_, T> {}

        let result = Cell::new(true);
        _ = [IsMonitorResource::<T> {
            is_monitor_resource: &result,
            _marker: PhantomData,
        }]
        .clone();

        result.get()
    }

    pub const fn add_down_callback<T: MonitorResource>(self) -> Self {
        Self {
            init: ErlNifResourceTypeInit {
                down: resource_down::<T> as *const ErlNifResourceDown,
                ..self.init
            },
            ..self
        }
    }

    pub fn initialize(env: Env) {
        for reg in inventory::iter::<Self>() {
            reg.register(env);
        }
    }

    pub fn register(&self, env: Env) {
        let type_id = (self.get_type_id)();
        let type_name = (self.get_type_name)();

        let res: Option<*const ErlNifResourceType> = unsafe {
            open_resource_type(
                env.as_c_arg(),
                CString::new(type_name).unwrap().as_bytes_with_nul(),
                self.init,
                ErlNifResourceFlags::ERL_NIF_RT_CREATE,
            )
        };
        unsafe { traits::register_resource_type(type_id, res.unwrap()) }
    }
}

#[macro_export]
macro_rules! register_resource_type {
    {$name:ty} => {
        $crate::codegen_runtime::inventory::submit!(
            $crate::codegen_runtime::ResourceRegistration::new::<#name>()
        );
    }
}

/// Drop a T that lives in an Erlang resource
unsafe extern "C" fn resource_destructor<T>(_env: *mut ErlNifEnv, handle: *mut c_void)
where
    T: Resource,
{
    let env = Env::new(&_env, _env);
    let aligned = align_alloced_mem_for_struct::<T>(handle);
    // Destructor takes ownership, thus the resource object will be dropped after the function has
    // run.
    ptr::read::<T>(aligned as *mut T).destructor(env);
}

unsafe extern "C" fn resource_down<T: MonitorResource>(
    env: *mut ErlNifEnv,
    obj: *mut c_void,
    pid: *const ErlNifPid,
    mon: *const ErlNifMonitor,
) {
    let env = Env::new(&env, env);
    let aligned = align_alloced_mem_for_struct::<T>(obj);
    let res = &*(aligned as *const T);
    let pid = LocalPid::from_c_arg(*pid);
    let mon = Monitor::from_c_arg(*mon);

    res.down(env, pid, mon);
}

pub unsafe fn open_resource_type(
    env: *mut ErlNifEnv,
    name: &[u8],
    init: ErlNifResourceTypeInit,
    flags: ErlNifResourceFlags,
) -> Option<*const ErlNifResourceType> {
    // Panic if name is not null-terminated.
    assert_eq!(name.last().cloned(), Some(0u8));

    let name_p = name.as_ptr() as *const c_char;

    let res = {
        let mut tried = MaybeUninit::uninit();
        rustler_sys::enif_open_resource_type_x(env, name_p, &init, flags, tried.as_mut_ptr())
    };

    if res.is_null() {
        None
    } else {
        Some(res)
    }
}
