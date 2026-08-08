// sandbox-launcher — Strategy A from the sandbox design note.
//
// The app cannot sandbox pi from the outside: sandbox_apply(profile, pid)
// falls back to sandboxing the *caller* when task_for_pid fails (verified —
// it sandboxed the app itself). The reliable mechanism is self-application:
// this tiny launcher applies the Seatbelt policy to ITSELF, then execs the
// real executable. The sandbox survives exec and is inherited by everything
// the exec'd process spawns.
//
// Usage: sandbox-launcher <executable> [args...]
// Policy: read from the PI_SANDBOX_POLICY environment variable.
//
// The unsandboxed window is this file's own startup only (reading one env
// var), which is exactly the "config loading only" window the design note
// prescribes for Strategy A. On any failure the launcher exits non-zero with
// a message on stderr; the caller sees the exit and fails closed.

#include <sandbox.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *policy = getenv("PI_SANDBOX_POLICY");
    if (policy == NULL || policy[0] == '\0') {
        fprintf(stderr, "sandbox-launcher: PI_SANDBOX_POLICY is not set\n");
        return 1;
    }
    if (argc < 2) {
        fprintf(stderr, "sandbox-launcher: no executable given\n");
        return 1;
    }

    char *error = NULL;
    if (sandbox_init(policy, 0, &error) != 0) {
        fprintf(stderr, "sandbox-launcher: sandbox_init failed: %s\n",
                error != NULL ? error : "unknown error");
        return 2;
    }

    // execv preserves the sandbox, all inherited file descriptors (the RPC
    // pipes) and the environment (proxy vars, policy). argv[1] becomes the
    // new process's argv[0].
    execv(argv[1], &argv[1]);
    fprintf(stderr, "sandbox-launcher: exec failed: %s\n", strerror(errno));
    return 3;
}
