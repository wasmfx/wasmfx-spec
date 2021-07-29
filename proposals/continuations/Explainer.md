# Typed Continuations as a Structured Basis for Non-Local Control Flow

This explainer document provides an informal presentation of the
*typed continuations* proposal, which is a minimal and compatible
extension to Wasm for structured non-local control flow. The proposal
is minimal in the sense that it leverages the existing instruction set
and extends it only with the bare minimum number of instructions to
suspend, resume, and abort computations. It is compatible in the sense
that: a) it is backward compatible with legacy code, 2) it respects
the Wasm philosophy: typed continuations admit a simple static and
operational semantics.

SL: I don't think the *compatible* part adds much; consider deleting

## Table of contents

1. [Motivation](#motivation)
2. [Additional Requirements](#additional-requirements)
3. [Proposal](#proposal)
   1. [Declaring Control Tags](#declaring-control-tags)
   2. [Creating Continuations](#creating-continuations)
   3. [Resuming Continuations](#resuming-continuations)
   4. [Suspending Continuations](#suspending-continuations)
   5. [Control Barriers](#control-barriers)
4. [Examples](#examples)
5. [Implementation strategies](#implementation-strategies)
   1. [Segmented Stacks](#segmented-stacks)
6. [FAQ](#faq)

## Motivation

Non-local control flow features provide the ability to suspend the
current execution context and later resume it. Many
industrial-strength programming languages feature a wealth of
non-local control flow features such as async/await, coroutines,
generators/iterators, effect handlers, call/cc, and so forth. For some
programming languages non-local control flow is central to their
identity, meaning that they rely on non-local control flow for
efficiency, e.g. to support massively scalable concurrency. Currently,
Wasm lacks support for implementing these features directly and
efficiently without a circuitous global transformation of source
programs on the producer side. One possible strategy is to add special
support for each of the aforementioned non-local control flow feature
to Wasm, however, this strategy is not sustainable as it does not
scale to the next 700 non-local control flow features. Instead, the
goal of this proposal is to introduce a unifed structured mechanism
that is sufficiently general to cover present use-cases as well as
being forwards compatible with future use-cases, while admitting
efficient implementations. The proposed mechanism is dubbed *typed
continuations*, and technically amounts to a low-level variation of
Plotkin and Pretnar's *effect handlers*.

SL: explain why it's *typed continuations*?

SL: link to something about effect handlers?

SL: It may be a bit confusing to bandy around all of this terminology
(typed continuations and effect handlers) without more context.

A *continuation* is a first-class program object that represents the
remainder of computation from a certain point in the execution of a
program. The typed continuations proposal is based on a structured
notion of delimited continuations. A *delimited continuation* is a
continuation whose extent is delimited by some *control delimiter*,
meaning it represents the remainder of computation from a certain
point in time up to (and possibly including) its control
delimiter. The alternative to delimited continuations is undelimited
continuations, which represent the remainder of the *entire*
program. Between the two notions delimited continuations are
preferable as they are more fine-grained in the sense that they
provide a means for suspending local execution contexts rather than
the entire global execution context. In particular, delimited
continuations are more expressive, as an undelimited continuation is
just a delimited continuation whose control delimiter is placed at the
start of the program.

SL: explain how an efficient way of implementing continuations is as
stacks (though other implementations are also possible)

The crucial feature of the typed continuations proposal that makes it
more structured than conventional delimited continuations is *control
tags*. A control tag is a typed symbolic entity that suspends the
current execution context and reifies it as a *continuation object*
(henceforth, just *continuation*) up to its control delimiter. The
type of a control tag communicates the type of its payload as well as
its expected return type, i.e. the type of data that must be supplied
to its associated continuation upon resumption. In other words,
control tags define an *interface* for constructing continuations. A
second aspect of the design that aids modularity by separating
concerns is that the construction of continuations is distinct from
*handling* of continuations. A continuation is handled at the
delimiter of a control tag rather than at the invocation site of the
control tag.

SL: point out that a control tag is just a standard Wasm tag as used
elsewhere in Wasm (e.g. in the exceptions proposal), though we do make
use of the `result` component of tags where other Wasm features (in
particular exceptions) may not

### Typed Continuation Primer

TODO
* [x] Introduce the concept of delimited continuations
* [x] Control tags (aka. effectful operations)
* [x] Invocation of control tags
* [ ] Abortion of suspended computations
* [ ] Linearity constraint
* [ ] Mention the connection with stacks early on
* [ ] Intuition: asymmetric coroutines sprinkled with some effect handlers goodies

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

 * **No GC dependency**: We intend every language to be able to use
   typed continuations to implement non-local flow abstractions
   irrespective of whether its memory is managed by a GC. Thus this
   proposal must not depend on a full-blown GC, rather, reference
   counting or a similar technique must be sufficient in cases where
   some form of memory management is necessary.

 * **Debugging friendliness**: The addition of continuations must
   preserve compatibility with standard debugging formats such as
   DWARF, meaning it must be possible to obtain a sequential
   unobstructed stack trace in the presence of continuations.

 * **Exception handling compatibility**: [The exception handling
   proposal](https://github.com/WebAssembly/exception-handling) adds
   special support for one kind of non-local control flow abstraction,
   namely, exception handlers. Exceptions must continue to work in the
   presence of typed continuations and vice versa.

 * **Preserve Wasm invariants of legacy code**: The proposal must be
   backwards compatibile with existing Wasm code. In particular, this
   means that the presence of typed continuations should not break
   invariants of existing code, e.g. code that expects to be executed
   once should not suddenly be executed twice.

## Proposal

The proposal adds a new reference type for continuations.

```wat
(cont ([t1*] -> [t2*]))
```

The continuation type is indexed by a function type, where `t1*`
describes the expected stack shape prior to resuming/starting the
continuation, and `t2*` describes the stack shape after the
continuation has run to completion.

### Declaring Control Tags

A control tag is similar to an exception extended with a result
type. Operationally, a control tag may be thought of as a *resumable*
exception. A tag declaration provides the type signature of a control
tag.

```wat
(tag $label (param tp*) (result tr*))
```

The `$label` is the name of the operation. The parameter types `tp*`
describe the expected stack layout prior to invoking the tag, and the
result types `tr*` describe the stack layout following an invocation
of the operation.

### Creating Continuations

The following instruction creates a continuation in *suspended state*
from a function.

```wat
cont.new : [(ref ([t1*] -> [t2*])] -> [(cont ([t1*] -> [t2*]))]

```

The instruction expects the top of the stack to contain a reference to
a function of type `[t1*] -> [t2*]`. The body of this function is a
computation that may perform non-local control flow.


### Resuming Continuations

There are three ways to resume (or start) a continuation. The first
way resumes the continuation under a named *handler*, which handles
subsequent control suspensions within the continuation.

```wat
cont.resume (tag $name $handler)* : [tr* (cont ([tr*] -> [t2*]))] -> [t2*]
```

The `cont.resume` instruction is parameterised by a collection of *tag
clauses*, each of which maps a control tag name to a handler for the
corresponding operation. This handler is a label that denotes a
pointer into the Wasm code. The instruction fully consumes its
continuation argument, meaning a continuation may be used only once.

The second way to resume a continuation is to raise an exception at
the control tag invocation site. This effectively amounts to
performing "an abortive action" which causes the stack to be unwound.


```wat
cont.throw (exception $exn) : [tp* (cont $ft)] -> [t2*]
```

The instruction `cont.throw` is parameterised by the exception to be
raised at the control tag invocation site. As with `cont.resume`, this
instruction also fully consumes its continuation
argument. Operationally, this instruction raises the exception `$exn`
with parameters of type `tp*` at the control tag invocation point in
the context of the supplied continuation.

The third way does not resume the continuation *per se*, rather, it
provides a way to partially apply a continuation to some of its
arguments.

```wat
cont.bind $ct : [tp* (cont ([tp* tp'*] -> [t2*]))] -> [(cont ([tp'*] -> [t2*]))]
```

The instruction `cont.bind` binds the arguments of type `tp*` to the
continuation `$ct`, yielding a modified continuation which expects
fewer arguments. As with the two previous instructions, this
instruction also consumes its continuation argument, though, in
contrast to the other two it yields a new continuation that can be
supplied to either `cont.{resume,throw,bind}`.

SL: might be worth pointing out somewhere that a handler associated
with `cont.resume` will also yield a new continuation whenever it
handles an operation

(The `cont.bind` instruction is directly analogous to the somewhat
controversial `func.bind` instruction from the function references
proposal. A potential problem with the latter that the former avoids
relates to its lifetime. As continuations are currently single-shot,
and compilers should ensure that they are always tidied up with
`cont.throw` if they are never actually resumed, the lifetime is
well-defined and there is no need for garbage collection.)

### Suspending Continuations

A computation running inside a continuation can suspend itself by
invoking one of the declared control tags.


```wat
cont.suspend $label : [tp*] -> [tr*]

```

The instruction `cont.suspend` invokes the control tag named `$label`
with arguments of types `tp*`. Operationally, the instruction
transfers control out of the continuation to the nearest enclosing
handler for `$label`. This behaviour is similar to how raising an
exception transfers control to the nearest exception handler that
handles the exception. The key difference is that the continuation at
the suspension point expects to be resumed later with arguments of
types `tr*`.

### Control Barriers

TODO

## Examples

### Lightweight threads (static)

(The full code for this example is [here](examples/static-lwt.wast).)

Lightweight threads are one of the primary use-cases for typed
continuations. In their most basic *static* form we assume a fixed
collection of cooperative threads with a single tag that allows a
thread to signal that it is willing to yield.

```wasm
(module $lwt
  (event $yield (export "yield"))
)
(register "lwt")
```

The `$yield` tag takes no parameter and has no result. Having
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
tag, because we have not yet specified how to handle it.

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
resuming the continuation with a handler for the `$yield` tag. The
handler `(event $yield $on_yield)` specifies that the `$yield` tag
is handled by running the code immediately following the block
labelled with `$on_yield`, the `$on_yield` clause. The result of the
block `(result (ref $cont))` declares that there will be a
continuation on the stack when suspending with the `$yield` tag,
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

We declare a new `$fork` tag that takes a continuation as a
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
handle both `$yield` and `$fork` tags. Yielding carries on executing
the current thread (this scheduler is synchronous). Forking enqueues
the new thread and continues executing the current thread.

As with the static example, the result of the `$on_yield` block
`(result (ref $cont))` declares that there will be a continuation on
the stack when suspending with the `$yield` tag, which is the
continuation of the currently executing thread. The result of the
`$on_fork` block `(result (ref $cont) (ref $cont))` declares that
there will be two continuations on the stack when suspending with the
`$fork` tag: the first is the parameter passed to fork (the new
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

## Implementation strategies

### Segmented Stacks

Segmented stacks is a state-of-the-art implementation technique for
continuations (cite: Dybvig et al., Chez Scheme, Multicore OCaml). The
principal idea underpinning segmented stacks is to view each
continuation as representing a separate stack.

Initially there is one stack, which may create other stacks. Each
child stack may create further stacks. Lineage of stacks is maintained
by linking children to their parent.

```ioke
      (stack 1)
       (active)
 |---------------------|
 |                     |
>| ...                 |
 |                     |
 | $c = cont.new $f    |
 | $h1                 |
 | cont.resume $h1 $c  |
 .                     .
 .                     .

```

The first stack may perform some computation, before the stack pointer
`>` moves to the `cont.new` instruction. Execution of the `cont.new`
instruction creates a new suspended stack for the computation implied
by `$f`.


```ioke
      (stack 1)                         (stack 2)
       (active)
 |---------------------|
 |                     |
 | ...                 |
 |                     |                 (suspended)
>| $c = cont.new $f -------------> |---------------------|
 | $h1                 |           | $f()                |
 | cont.resume $h1 $c  |           |                     |
 .                     .           .                     .
 .                     .           .                     .
                                   .                     .

```

Stack 1 maintains control after the creation of stack 2, and thus
execution continues on stack 1 until the stack pointer reaches the
`cont.resume` instruction. The `cont.resume` instruction suspends
stack 1 and transfers control to new stack 2. The transfer of control
reverses the parent-child link, such that stack 2 now points back to
stack 1.

```ioke
      (stack 1)                         (stack 2)
       (active)
 |---------------------|
 |                     |
 | ...                 |
 |                     |                 (suspended)
 | $c = cont.new $f    |       ----|---------------------|
 | $h1                 |<-----/    | $f()                |
>| cont.resume $h1 $c  |           |                     |
 .                     .           .                     .
 .                     .           .                     .
                                   .                     .
```

The stack pointer moves to the top of stack 2, and thus execution
continues on stack 2.


```ioke
      (stack 1)                         (stack 2)
       (suspended)
 |---------------------|
 |                     |
 | ...                 |
 |                     |                 (active)
 | $c = cont.new $f    |       ----|---------------------|
 | $h1                 |<-----/   >| $f()                |
 |                     |           |                     |
 .                     .           .                     .
 .                     .           .                     .
                                   .                     .
```

Later we may want to resume the resumption `r` again with
the result `42`: (`r(42)`)

## FAQ

### Shift/reset or control/prompt as an alternative basis

An alternative to typed continuations is to use more classical
delimited continuations arising from operators such as shift/reset and
control/prompt. As seen in the examples section shift/reset can be
viewed as a special instance of our proposal with a single control tag
`shift` and a handler for each `reset`. Thus every non-local control
flow abstraction has to be codified via a single control tag, which
makes static typing considerably more difficult. In order to preserve
static type-safety operators like shift/reset require something like
*answer-type modification*, which would be a fairly profound addition
to the Wasm type system.

### Tail-resumptive handlers

A handler is said to be *tail-resumptive* if the handler invokes the
continuation in tail-position in every control tag clause. A classical
example of a tail-resumptive handler is dynamic binding (which can be
useful to implement implicit parameters to computations). The key
insight is that the control tag clauses of a tail-resumptive handler
can be inlined at the control tag invocation sites, because they do
not perform any fancy control flow manipulation, they simply "retrieve
a value", as it were. The gain by inlining the clause definitions is
that computation need not spend time constructing continuations.

The present iteration of this proposal do not support facilities for
identifying and inlining tail-resumptive handlers as there does not
yet exist any real-world workloads that suggest optimising for
tail-resumptive handlers is worth the additional
complexity. Furthermore, a feature such as dynamic binding can already
be efficiently simulated in Wasm by way of mutable reference cells.

### Multi-shot continuations

Our continuations are single-shot, or more precisely, *linear*,
meaning they have to be invoked exactly once. An invocation can be
either resumptive or abortive. An alternative is to allow an unbounded
number of invocations of continuations. Such continuations are
colloquially known as *multi-shot* continuations. Multi-shot
continuations can be useful for a variety of use-cases such as
implementing backtracking, probabilistic programming, process
duplication, and many more. However, the main problem with multi-shot
continuations is that they do not readily preserve
backwards-compatibility with legacy code as every computation may
repeated multiple times, which can be problematic in the presence of
linear resources such as sockets.  The linearity restriction imposed
on continuations by this proposal is absolutely crucial in order to
preserve invariants of legacy code.

Another reason to prefer single-shot continuations over multi-shot
continuations is efficiency. Single-shot continuations do not require
any stack copying on imperative runtimes (i.e. runtimes that based on
mutation of the stack/registers), whereas multi-shot continuations
need to be copied prior to invocation in order to ensure that a
subsequent invocation can take place.

### Named control tag dispatch
TODO

