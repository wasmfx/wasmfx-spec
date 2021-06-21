# Typed Continuations as a Structured Basis for Non-Local Control Flow

This explainer document provides an informal presentation of the
*typed continuations* proposal, which is a minimal extension to Wasm
for structured non-local control flow.

## Table of contents

1. [Motivation](#motivation)
2. [Additional Requirements](#additional-requirements)
3. [Proposal](#proposal)
   1. [Declaring Control Events](#declaring-control-events)
   2. [Creating Continuations](#creating-continuations)
   3. [Resuming Continuations](#resuming-continuations)
   4. [Suspending Continuations](#suspending-continuations)
4. [Examples](#examples)
5. [FAQ](#faq)

## Motivation

Industrial-strength programming languages feature a wealth of
non-local control flow abstractions such as async/await, coroutines,
generators/iterators, effect handlers, call/cc, and so forth. The
identity of some programming languages depends on non-local control
flow for efficiency, e.g. to support highly scalable
concurrency. Currently, Wasm lacks support for implementing these
abstractions directly and efficiently without a circuitous global
transformation of source programs on the producer side.  One possible
strategy is to add special support for each of the aforementioned
non-local control flow abstractions to Wasm, however, this strategy is
not sustainable as it does not scale to the next 700 non-local control
flow abstractions. Instead, the goal of this proposal is to introduce
a structured unified mechanism, which is sufficiently general to cover
the present use-cases as well as being compatible with future
use-cases, whilst admitting efficient implementations.  The proposed
mechanism is dubbed *typed continuations*, which essentially amounts
to a low-level variation of Plotkin and Pretnar's *effect handlers*.

### Typed Continuation Primer

TODO
* Introduce the concept of delimited continuations
* Control events (aka. effectful operations)
* Invocation of control events
* Abortion of suspended computations
* Linearity constraint

<!-- Many industrial-grade programming languages feature non-local control
flow abstractions such as async/await (C#/F#/JavaScript/Rust/Scala),
coroutines (C++/Go/Smalltalk), generators/iterators
(C#/F#/Haskell/JavaScript/Racket/Python), effect handlers (OCaml),
call/cc (Racket), and so forth. Currently, Wasm lacks support for
implementing such control flow abstractions efficiently, since Wasm
does not provide any primitives for manipulating segments of the
execution stack. One possible approach is to add special support for
each of the aforementioned control abstractions, though, what about
the next 700 control abstractions? Adding individual support is not a
sustainable strategy as it does not scale. Instead, the goal of this
proposal is to introduce a general structured mechanism, which enables
the aforementioned and the next 700 control abstractions to be
implemented efficiently. Specifically, the idea is to provide an
interface for structured manipulation of the execution stack via
*typed delimited continuations*.-->
<!-- TODO mention highly scalable concurrency a la Erlang as a use case -->

## Additional Requirements

 * **No GC dependency**: We intend every host to be able to use typed
   continuations implement their non-local flow abstractions
   irrespective of whether their memory is managed by a GC. Thus this
   proposal must not depend on a full-blown GC, rather, reference
   counting or a similar technique must be sufficient in cases where
   some form of memory management is necessary.

## Proposal

The proposal adds a new reference type for continuations.

```wat
(cont ([t1*] -> [t2*]))
```

The continuation type is indexed by a function type, where `t1*`
describes the expected stack shape prior to resuming/starting the
continuation, and `t2*` describes the stack shape after the
continuation has run to completion.

### Declaring Control Events

A control event is similar to an exception with the addition that it
has a result type. Operationally, a control event may be thought of as
a *resumable* exception. An event declaration provides the type
signature of a control event.

```wat
(event $label (param tp*) (result tr*))
```

The `$label` is the name of the operation. The parameter types `tp*`
describes the expected stack layout prior to invoking the event,
and the result types `tr*` describes the stack layout following an
invocation of the operation.

### Creating Continuations

The following instruction creates a continuation object in *suspended
state* from a function.

```wat
cont.new : [(ref ([t1*] -> [t2*])] -> [(cont ([t1*] -> [t2*]))]

```

The instruction expects the top of the stack to contain a reference to
a function of type `[t1*] -> [t2*]`. This function embodies a
computation that may perform non-local control flow transfers.


### Resuming Continuations

There are three ways to resume (or start) a continuation object. The
first way resumes a continuation under a named *handler*, which handles
subsequent control suspensions within the continuation.

```wat
cont.resume (event $label $handler)* : [tr* (cont ([tr*] -> [t2*]))] -> [t2*]
```

The `cont.resume` instruction is parameterised by a collection of
*event clauses*, which maps control event names to their respective
handlers in the residual computation of the continuation object. The
instruction `cont.resume` fully consumes its continuation argument,
meaning a continuation object can only be used once.

The second way to resume a continuation object is to raise an
exception at the control event invocation site. This effectively
amounts to performing "an abortive action" which causes the stack to
be unwound.


```wat
cont.throw (exception $exn) : [tp* (cont $ft)] -> [t2*]
```

The instruction `cont.throw` is parameterised by the exception to be
raised at the control event invocation site. As with `cont.resume`,
this instruction also fully consumes its continuation object
argument. Operationally, this instruction injects the exception `$exn`
with parameters of type `tp*` at the control event invocation point in
the residual computation of the provided continuation object.

The third way does not resume the continuation *per see*, rather, it
provides a way to partially apply a continuation to some of its
arguments.

```wat
cont.bind $ct : [tp* (cont ([tp* tp'*] -> [t2*]))] -> [(cont ([tp'*] -> [t2*]))]
```

The instruction `cont.bind` binds the arguments of type `tp*` to the
continuation `$ct`, yielding a modified continuation object which
expects fewer arguments. As with the two previous instructions, this
instruction does also consume its continuation object argument,
though, in contrast to the other two it produces a new continuation
object that can be supplied to either `cont.{resume,throw,bind}`.

### Suspending Continuations

A computation running inside a continuation object can suspend itself
by invoking one of the declared control events.


```wat
cont.suspend $label : [tp*] -> [tr*]

```

The instruction `cont.suspend` invokes the control event named
`$label` with arguments of types `tp*`. Operationally, the instruction
transfers control out of the continuation object to nearest enclosing
handler for `$label`. This is similar to how raising an exception
transfers control to the nearest suitable exception handler. The
crucial difference is the residual computation at the suspension point
expects to resumed later with arguments of types `tr*`.

## Examples

### Lightweight threads (static)

(The full code for this example is [here](examples/static-lwt.wast).)

Lightweight threads are one of the primary use-cases for typed
continuations. In their most basic *static* form we assume a fixed
collection of cooperative threads with a single event that allows a
thread to signal that it is willing to yield.

```wasm
(module $lwt
  (event $yield (export "yield"))
)
(register "lwt")
```

The `$yield` event takes no parameter and has no result. Having
declared it, we can now write some cooperative threads as functions.

```wasm
(module $example
  (event $yield (import "lwt" "yield"))
  (func $log (import "spectest" "print_i32") (param i32))

  (func $thread1 (export "thread1")
    (call $log (i32.const 10))
    (suspend $yield)
    (call $log (i32.const 11))
    (suspend $yield)
    (call $log (i32.const 12))
  )

  (func $thread2 (export "thread2")
    (call $log (i32.const 20))
    (suspend $yield)
    (call $log (i32.const 21))
    (suspend $yield)
    (call $log (i32.const 22))
  )

  (func $thread3 (export "thread3")
    (call $log (i32.const 30))
    (suspend $yield)
    (call $log (i32.const 31))
    (suspend $yield)
    (call $log (i32.const 32))
  )
)
(register "example")
```

Our intention is to interleave the execution of `$thread1`,
`$thread2`, and `$thread3`, using `(suspend $yield)` to suspend
execution to a scheduler which will perform a context switch.

If we were to try to run any of these functions at the top-level then
they would trap as soon as they try to suspend with the `$yield$`
event, because we have not yet specified how to handle it.

We now define a scheduler.

```wasm
(module $scheduler
  (type $func (func))
  (type $cont (cont $func))

  (event $yield (import "lwt" "yield"))

  ;; queue interface
  (func $queue-empty (import "queue" "queue-empty") (result i32))
  (func $dequeue (import "queue" "dequeue") (result (ref null $cont)))
  (func $enqueue (import "queue" "enqueue") (param $k (ref $cont)))

  (func $run (export "run")
    (loop $l
      (if (call $queue-empty) (then (return)))
      (block $on_yield (result (ref $cont))
        (resume (event $yield $on_yield)
                (call $dequeue)
        )
        (br $l)  ;; thread terminated
      ) ;;   $on_yield (result (ref $cont))
      (call $enqueue)  ;; continuation of current thread
      (br $l)
    )
  )
)
(register "scheduler")
```

We assume a suitable interface to a queue of active threads
represented as continuations. The scheduler is a loop which repeatedly
runs the continuation (thread) at the head of the queue. It does so by
resuming the continuation with a handler for the `$yield` event. The
handler `(event $yield $on_yield)` specifies that the `$yield` event
is handled by running the code immediately following the block
labelled with `$on_yield`, the `$on_yield` clause. The result of the
block `(result (ref $cont))` declares that there will be a
continuation on the stack when suspending with the `$yield` event,
which is the continuation of the currently executing thread. The
`$on_yield` clause enqueues this continuation and proceeds to the next
iteration of the loop.

In order to interleave our three test threads together, we create a
new continuation for each, enqueue the continuations, and invoke the
scheduler. The `cont.new` operation turns a function reference into a
corresponding continuation reference.

```wasm
(module
  (type $func (func))
  (type $cont (cont $func))

  (func $scheduler (import "scheduler" "run"))
  (func $enqueue (import "queue" "enqueue") (param (ref $cont)))

  (func $log (import "spectest" "print_i32") (param i32))

  (func $thread1 (import "example" "thread1"))
  (func $thread2 (import "example" "thread2"))
  (func $thread3 (import "example" "thread3"))

  (elem declare func $thread1 $thread2 $thread3)

  (func (export "run")
    (call $enqueue (cont.new (type $cont) (ref.func $thread1)))
    (call $enqueue (cont.new (type $cont) (ref.func $thread2)))
    (call $enqueue (cont.new (type $cont) (ref.func $thread3)))

    (call $log (i32.const -1))
    (call $scheduler)
    (call $log (i32.const -2))
  )
)

(invoke "run")
```

The output is as follows.
```
-1 : i32
10 : i32
20 : i32
30 : i32
11 : i32
21 : i32
31 : i32
12 : i32
22 : i32
32 : i32
-2 : i32
```
The threads are interleaved as expected.

### Lightweight threads (dynamic)

(The full code for this example is [here](examples/lwt.wast).)

We can make our lightweight threads functionality considerably more
expressive by allowing new threads to be forked dynamically.

```wasm
(module $lwt
  (type $func (func))
  (type $cont (cont $func))

  (event $yield (export "yield"))
  (event $fork (export "fork") (param (ref $cont)))
)
(register "lwt")
```

We declare a new `$fork` event that takes a continuation as a
parameter and (like `$yield`) returns no result. Now we modify our
example to fork each of the three threads from a single main thread.

```wasm
(module $example
  (type $func (func))
  (type $cont (cont $func))

  (event $yield (import "lwt" "yield"))
  (event $fork (import "lwt" "fork") (param (ref $cont)))

  (func $log (import "spectest" "print_i32") (param i32))

  (elem declare func $thread1 $thread2 $thread3)

  (func $main (export "main")
    (call $log (i32.const 0))
    (suspend $fork (cont.new (type $cont) (ref.func $thread1)))
    (call $log (i32.const 1))
    (suspend $fork (cont.new (type $cont) (ref.func $thread2)))
    (call $log (i32.const 2))
    (suspend $fork (cont.new (type $cont) (ref.func $thread3)))
    (call $log (i32.const 3))
  )

  (func $thread1
    (call $log (i32.const 10))
    (suspend $yield)
    (call $log (i32.const 11))
    (suspend $yield)
    (call $log (i32.const 12))
  )

  (func $thread2
    (call $log (i32.const 20))
    (suspend $yield)
    (call $log (i32.const 21))
    (suspend $yield)
    (call $log (i32.const 22))
  )

  (func $thread3
    (call $log (i32.const 30))
    (suspend $yield)
    (call $log (i32.const 31))
    (suspend $yield)
    (call $log (i32.const 32))
  )
)
(register "example")
```

As with the static example we define a scheduler module.
```wasm
(module $scheduler
  (type $func (func))
  (type $cont (cont $func))

  (event $yield (import "lwt" "yield"))
  (event $fork (import "lwt" "fork") (param (ref $cont)))

  (func $queue-empty (import "queue" "queue-empty") (result i32))
  (func $dequeue (import "queue" "dequeue") (result (ref null $cont)))
  (func $enqueue (import "queue" "enqueue") (param $k (ref null $cont)))
  ...
)
(register "scheduler")
```

In this example we illustrate five different schedulers. First, we
write a baseline synchronous scheduler which simply runs the current
thread to completion without actually yielding.

```wasm
  (func $sync (export "sync") (param $nextk (ref null $cont))
    (loop $l
      (if (ref.is_null (local.get $nextk)) (then (return)))
      (block $on_yield (result (ref $cont))
        (block $on_fork (result (ref $cont) (ref $cont))
          (resume (event $yield $on_yield)
                  (event $fork $on_fork)
                  (local.get $nextk)
          )
          (local.set $nextk (call $dequeue))
          (br $l)  ;; thread terminated
        ) ;;   $on_fork (result (ref $cont) (ref $cont))
        (local.set $nextk)                      ;; current thread
        (call $enqueue) ;; new thread
        (br $l)
      )
      ;;     $on_yield (result (ref $cont))
      (local.set $nextk)  ;; carry on with current thread
      (br $l)
    )
  )
```

The `$nextk` parameter represents the continuation of the next
thread. The loop is repeatedly executed until `$nextk` is null
(meaning that all threads have finished). The body of the loop is the
code inside the two nested blocks. It resumes the next continuation,
dequeues the next continuation, and then continues to the next
iteration of the loop. The handler passed to `resume` specifies how to
handle both `$yield` and `$fork` events. Yielding carries on executing
the current thread (this scheduler is synchronous). Forking enqueues
the new thread and continues executing the current thread.

As with the static example, the result of the `$on_yield` block
`(result (ref $cont))` declares that there will be a continuation on
the stack when suspending with the `$yield` event, which is the
continuation of the currently executing thread. The result of the
`$on_fork` block `(result (ref $cont) (ref $cont))` declares that
there will be two continuations on the stack when suspending with the
`$fork` event: the first is the parameter passed to fork (the new
thread) and the second is the continuation of the currently executing
thread.

Running the synchronous scheduler on the example produces the following output.
```
0 : i32
1 : i32
2 : i32
3 : i32
10 : i32
11 : i32
12 : i32
20 : i32
21 : i32
22 : i32
30 : i32
31 : i32
32 : i32
```
First the main thread runs to completion, then each of the forked
threads in sequence.

Following a similar pattern, we define four different asynchronous
schedulers.

```wasm
  ;; four asynchronous schedulers:
  ;;   * kt and tk don't yield on encountering a fork
  ;;     1) kt runs the continuation, queuing up the new thread for later
  ;;     2) tk runs the new thread first, queuing up the continuation for later
  ;;   * ykt and ytk do yield on encountering a fork
  ;;     3) ykt runs the continuation, queuing up the new thread for later
  ;;     4) ytk runs the new thread first, queuing up the continuation for later

  ;; no yield on fork, continuation first
  (func $kt (export "kt") (param $nextk (ref null $cont))
    (loop $l
      (if (ref.is_null (local.get $nextk)) (then (return)))
      (block $on_yield (result (ref $cont))
        (block $on_fork (result (ref $cont) (ref $cont))
          (resume (event $yield $on_yield)
                  (event $fork $on_fork)
                  (local.get $nextk)
          )
          (local.set $nextk (call $dequeue))
          (br $l)  ;; thread terminated
        ) ;;   $on_fork (result (ref $cont) (ref $cont))
        (local.set $nextk)                      ;; current thread
        (call $enqueue) ;; new thread
        (br $l)
      )
      ;;     $on_yield (result (ref $cont))
      (call $enqueue)                    ;; current thread
      (local.set $nextk (call $dequeue)) ;; next thread
      (br $l)
    )
  )

  ;; no yield on fork, new thread first
  (func $tk (export "tk") (param $nextk (ref null $cont))
    (loop $l
      (if (ref.is_null (local.get $nextk)) (then (return)))
      (block $on_yield (result (ref $cont))
        (block $on_fork (result (ref $cont) (ref $cont))
          (resume (event $yield $on_yield)
                  (event $fork $on_fork)
                  (local.get $nextk)
          )
          (local.set $nextk (call $dequeue))
          (br $l)  ;; thread terminated
        ) ;;   $on_fork (result (ref $cont) (ref $cont))
        (call $enqueue)                            ;; current thread
        (local.set $nextk) ;; new thread
        (br $l)
      )
      ;;     $on_yield (result (ref $cont))
      (call $enqueue)                    ;; current thread
      (local.set $nextk (call $dequeue)) ;; next thread
      (br $l)
    )
  )

  ;; yield on fork, continuation first
  (func $ykt (export "ykt") (param $nextk (ref null $cont))
    (loop $l
      (if (ref.is_null (local.get $nextk)) (then (return)))
      (block $on_yield (result (ref $cont))
        (block $on_fork (result (ref $cont) (ref $cont))
          (resume (event $yield $on_yield)
                  (event $fork $on_fork)
                  (local.get $nextk)
          )
          (local.set $nextk (call $dequeue))
          (br $l)  ;; thread terminated
        ) ;;   $on_fork (result (ref $cont) (ref $cont))
        (call $enqueue)                         ;; current thread
        (call $enqueue) ;; new thread
        (local.set $nextk (call $dequeue))      ;; next thread
        (br $l)
      )
      ;;     $on_yield (result (ref $cont))
      (call $enqueue)                    ;; current thread
      (local.set $nextk (call $dequeue)) ;; next thread
      (br $l)
    )
  )

  ;; yield on fork, new thread first
  (func $ytk (export "ytk") (param $nextk (ref null $cont))
    (loop $l
      (if (ref.is_null (local.get $nextk)) (then (return)))
      (block $on_yield (result (ref $cont))
        (block $on_fork (result (ref $cont) (ref $cont))
          (resume (event $yield $on_yield)
                  (event $fork $on_fork)
                  (local.get $nextk)
          )
          (local.set $nextk (call $dequeue))
          (br $l)  ;; thread terminated
        ) ;;   $on_fork (result (ref $cont) (ref $cont))
        (local.set $nextk)
        (call $enqueue) ;; new thread
        (call $enqueue (local.get $nextk))      ;; current thread
        (local.set $nextk (call $dequeue))      ;; next thread
        (br $l)
      )
      ;;     $on_yield (result (ref $cont))
      (call $enqueue)                    ;; current thread
      (local.set $nextk (call $dequeue)) ;; next thread
      (br $l)
    )
  )
```

Each `$on_yield` clause is identical, enqueing the continuation of the
current thread and dequeing the next continuation for the thread. The
`$on_fork` clauses implement different behaviours for scheduling the
current and newly forked threads.

We run our example using each of the five schedulers.

```wasm
(module
  (type $func (func))
  (type $cont (cont $func))

  (func $scheduler1 (import "scheduler" "sync") (param $nextk (ref null $cont)))
  (func $scheduler2 (import "scheduler" "kt") (param $nextk (ref null $cont)))
  (func $scheduler3 (import "scheduler" "tk") (param $nextk (ref null $cont)))
  (func $scheduler4 (import "scheduler" "ykt") (param $nextk (ref null $cont)))
  (func $scheduler5 (import "scheduler" "ytk") (param $nextk (ref null $cont)))

  (func $log (import "spectest" "print_i32") (param i32))

  (func $main (import "example" "main"))

  (elem declare func $main)

  (func (export "run")
    (call $log (i32.const -1))
    (call $scheduler1 (cont.new (type $cont) (ref.func $main)))
    (call $log (i32.const -2))
    (call $scheduler2 (cont.new (type $cont) (ref.func $main)))
    (call $log (i32.const -3))
    (call $scheduler3 (cont.new (type $cont) (ref.func $main)))
    (call $log (i32.const -4))
    (call $scheduler4 (cont.new (type $cont) (ref.func $main)))
    (call $log (i32.const -5))
    (call $scheduler5 (cont.new (type $cont) (ref.func $main)))
    (call $log (i32.const -6))
  )
)

(invoke "run")
```

The output is as follows, demonstrating the various different scheduling behaviours.
```
-1 : i32
0 : i32
1 : i32
2 : i32
3 : i32
10 : i32
11 : i32
12 : i32
20 : i32
21 : i32
22 : i32
30 : i32
31 : i32
32 : i32
-2 : i32
0 : i32
1 : i32
2 : i32
3 : i32
10 : i32
20 : i32
30 : i32
11 : i32
21 : i32
31 : i32
12 : i32
22 : i32
32 : i32
-3 : i32
0 : i32
10 : i32
1 : i32
20 : i32
11 : i32
2 : i32
30 : i32
21 : i32
12 : i32
3 : i32
31 : i32
22 : i32
32 : i32
-4 : i32
0 : i32
1 : i32
10 : i32
2 : i32
20 : i32
11 : i32
3 : i32
30 : i32
21 : i32
12 : i32
31 : i32
22 : i32
32 : i32
-5 : i32
0 : i32
10 : i32
1 : i32
11 : i32
20 : i32
2 : i32
12 : i32
21 : i32
30 : i32
3 : i32
22 : i32
31 : i32
32 : i32
-6 : i32
```

### Actors (TODO)

### Async/await (TODO)

### Delimited continuations (TODO)

## FAQ

### Shift/reset or control/prompt as an alternative basis
TODO

### Tail-resumptive handlers
TODO

### Multi-shot continuations
TODO

