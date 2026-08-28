use crate::sys::enif_consume_timeslice;
use crate::wrapper::ErlNifTaskFlags;
use crate::Env;

pub enum SchedulerFlags {
    Normal = ErlNifTaskFlags::ERL_NIF_NORMAL_JOB as isize,
    DirtyCpu = ErlNifTaskFlags::ERL_NIF_DIRTY_JOB_CPU_BOUND as isize,
    DirtyIo = ErlNifTaskFlags::ERL_NIF_DIRTY_JOB_IO_BOUND as isize,
}

pub(crate) fn consume_timeslice_in_env(env: Env, percent: i32) -> bool {
    let success = unsafe { enif_consume_timeslice(env.as_c_arg(), percent) };
    success == 1
}

pub fn consume_timeslice(percent: i32) -> bool {
    Env::with_current(|env| consume_timeslice_in_env(env, percent))
}
