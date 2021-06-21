# Typed Continuations as a Structured Basis for Non-Local Control Flow

This explainer document provides an informal presentation of the
*typed continuations* proposal, which is a minimal extension to Wasm
for structured non-local control flow.

## Table of contents

1. [Motivation](#motivation)
2. [Additional Requirements](#additional-requirements)
3. [Proposal](#proposal)
   1. [Declaring Event Operations](#declaring-event-operations)
   2. [Creating Continuations](#creating-continuations)
   3. [Suspending Continuations](#suspending-continuations)
   4. [Resuming Continuations](#resuming-continuations)
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
non-local control flow abstraction to Wasm, however, this strategy is
not sustainable as it does not scale to the next 700 non-local control
flow abstractions. Instead, the goal of this proposal is to introduce
a structured unified mechanism, which is sufficiently general to cover
the present use-cases as well as being compatible with future
use-cases, whilst admitting efficient implementations.  The proposed
mechanism is dubbed *typed continuations*, which essentially amounts
to a low-level variation of Plotkin and Pretnar's *effect handlers*.

### Typed Continuation Primer

Intuitively, a delimited continuation represents a segment of the
execution stack...

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

### Declaring Event Operations

```wat
(event $label (param tp*) (result tr*))
```

### Creating Continuations

```wat
(cont $ft)
cont.new : [(ref ([t1*] -> [t2*])] -> [(cont ([t1*] -> [t2*]))]

```

### Suspending Continuations

```wat
cont.suspend $label : [tp*] -> [tr*]

```

### Resuming Continuations

```wat
cont.resume (event $label $handler)* : [tr*] -> [t1*]
```

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
continuation on the stack when suspending with the `$yield`
event. This continuation represents the remainder of the currently
executing thread. The `$on_yield` clause enqueues this continuation
and proceeds to the next iteration of the loop.

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

The threads are interleaved as expected, and the output is as follows.
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

### Lightweight threads (dynamic)

We can make our lightweight threads functionality considerably more
expressive by allowing new threads to be dynamically forked...


## FAQ
