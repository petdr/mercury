//
// Copyright (C) 2014 The Mercury Team
// This file may only be copied under the terms of the GNU Library General
// Public License - see the file COPYING.LIB in the Mercury distribution.
//

package jmercury.runtime;

/**
 * Interface to the Mercury Runtime System for Java code.
 *
 * No instance of this class is ever created, all its members and methods
 * are static.
 */
public class MercuryRuntime
{
    /**
     * Private constructor.
     * This private constructor doesn't do anything and isn't called by
     * anyone.  It exists only to prevent people from creating an instance.
     */
    private MercuryRuntime() {
    }

    private static MercuryThreadPool    thread_pool = null;

    /**
     * Return the thread pool, initialising it if required.
     * This does not start the thread pool.  It is started either when
     * startup() is called or automatically when the first task is
     * submitted.
     */
    public static synchronized MercuryThreadPool getThreadPool()
    {
        if (thread_pool == null) {
            thread_pool = new MercuryThreadPool(
                JavaInternal.getOptions().getNumProcessors());
        }
        return thread_pool;
    }

    /**
     * Retrieve the exit status stored in the I/O state.
     */
    public static int getExitStatus() {
        return JavaInternal.exit_status;
    }

    /**
     * Finalise the runtime system.
     * This _must_ be called at the end of any program.  It runs
     * finalisers and stops the thread pool.  This will wait for the thread
     * pool to shutdown (unless abort=true).
     */
    public static void finalise(boolean abort) {
        MercuryThreadPool pool;

        pool = getThreadPool();
        if (!abort) {
            JavaInternal.run_finalisers();
        }
        pool.shutdown(abort);
        if (!abort) {
            pool.waitForShutdown();
        }
    }

    /**
     * Finalise the runtime system.
     * This _must_ be called at the end of any program.  It runs
     * finalisers and stops the thread pool.  This will wait for the thread
     * pool to shutdown.
     * This is the same as calling finalise(false)
     */
    public static void finalise() {
        finalise(false);
    }
}

