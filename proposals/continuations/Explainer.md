# Typed Continuations

This document provides an informal presentation of the *typed
continuations* proposal, a minimal and compatible extension to Wasm
for structured non-local control flow. The proposal is minimal in the
sense that it leverages the existing instruction set and type
system. It extends the instruction set with instructions to suspend,
resume, and abort computations, and extends the type system with a
single new reference type for *continuations*.

**TODO**
* [x] Introduce the concept of delimited continuations
* [x] Control tags (aka. effectful operations)
* [x] Invocation of control tags
* [x] Abortion of suspended computations
* [ ] Linearity constraint
* [x] Mention the connection with stacks early on
* [ ] Intuition: asymmetric coroutines sprinkled with some effect handlers goodies

## Table of contents

1. [Motivation](#motivation)
2. [Additional Requirements](#additional-requirements)
3. [Instruction Set](#instruction-set)
   1. [Declaring Control Tags](#declaring-control-tags)
   2. [Creating Continuations](#creating-continuations)
   3. [Resuming Continuations](#resuming-continuations)
   4. [Suspending Continuations](#suspending-continuations)
   5. [Binding Continuations](#binding-continuations)
   6. [Trapping Continuations](#trapping-continuations)
4. [Examples](#examples)
5. [Implementation Strategies](#implementation-strategies)
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
efficiency, e.g. to support massively scalable concurrency.

Currently, Wasm lacks support for implementing such features directly
and efficiently without a circuitous global transformation of source
programs on the producer side. One possible strategy is to add special
support for each individual non-local control flow feature to Wasm,
but strategy does not scale to the next 700 non-local control flow
features. Instead, the goal of this proposal is to introduce a unifed
structured mechanism that is sufficiently general to cover present
use-cases as well as being forwards compatible with future use-cases,
while admitting efficient implementations.

The proposed mechanism is based on proven technology: *delimited
continuations*. An undelimited continuation represents the rest of a
computation from a certain point in its execution. A delimited
continuation is a more modular form of continuation, representing the
rest of a computation from a particular point in its execution up to a
*delimiter* or *prompt*. Operationally, one may think of undelimited
continuations as stacks and delimited continuations as segmented
stacks.

In their raw form delimited continuations do not readily fit into the
Wasm ecosystem, as the Wasm type system is not powerful enough to type
them. The gist of the problem is that the classic treatment of
delimited continuations provides only one universal control tag
(i.e. the mechanism which transforms a runtime stack into a
programmatic data object). In order to use Wasm's simple type system
to type delimited continuations, we use the idea of multiple *named*
control tags from Plotkin and Pretnar's effect handlers. Each control
tag is declared module-wide along its payload type and return
type. This declaration can be used to readily type points of non-local
transfer of control. From a operational perspective we may view
control tags as a means for writing an interface for the possible
kinds of non-local transfers (or stack switches) that a computation
may perform.

### Typed Continuation Primer

A *continuation* is a first-class program object that represents the
remainder of computation from a certain point in the execution of a
program. The typed continuations proposal is based on a structured
notion of delimited continuations. A *delimited continuation* is a
continuation whose extent is delimited by some *control delimiter*,
meaning it represents the remainder of computation from a certain
point up to (and possibly including) its control delimiter. An
alternative to delimited continuations is undelimited continuations
which represent the remainder of the *entire* program. Delimited
continuations are preferable as they are more modular and more
fine-grained in the sense that they provide a means for suspending
local execution contexts rather than the entire global execution
context. In particular, delimited continuations are more expressive,
as an undelimited continuation is merely a delimited continuation
whose control delimiter is placed at the start of the program.

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
control tag. Control tags are a mild extension of exception tags as in
the exception-handling proposal. The key difference is that in
addition to a payload type, a control tag also declares a return type.

Typed continuations may be efficiently implemented using segmented
stacks, but other implementations are also possible.

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

## Instruction Set

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
(tag $tag (param tp*) (result tr*))
```

The `$tag` is the name of the operation. The parameter types `tp*`
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


### Invoking Continuations

There are two ways to invoke (or run) a continuation. The first way
resumes the continuation under a named *handler*, which handles
subsequent control suspensions within the continuation.

```wat
resume (tag $tag $handler)* : [tr* (cont ([tr*] -> [t2*]))] -> [t2*]
```

The `resume` instruction is parameterised by a collection of *tag
clauses*, each of which maps a control tag name to a handler for the
corresponding operation. This handler is a label that denotes a
pointer into the Wasm code. The instruction fully consumes its
continuation argument, meaning a continuation may be used only once.

The second way to invoke a continuation is to raise an exception at
the control tag invocation site. This effectively amounts to
performing "an abortive action" which causes the stack to be unwound.


```wat
resume_throw (exception $exn) : [tp* (cont ([tr*] -> [t2*]))] -> [t2*]
```

The instruction `resume_throw` is parameterised by the exception to be
raised at the control tag invocation site. As with `resume`, this
instruction also fully consumes its continuation
argument. Operationally, this instruction raises the exception `$exn`
with parameters of type `tp*` at the control tag invocation point in
the context of the supplied continuation.


### Suspending Continuations

A computation running inside a continuation can suspend itself by
invoking one of the declared control tags.


```wat
suspend $tag : [tp*] -> [tr*]

```

The instruction `suspend` invokes the control tag named `$tag`
with arguments of types `tp*`. Operationally, the instruction
transfers control out of the continuation to the nearest enclosing
handler for `$tag`. This behaviour is similar to how raising an
exception transfers control to the nearest exception handler that
handles the exception. The key difference is that the continuation at
the suspension point expects to be resumed later with arguments of
types `tr*`.

### Binding Continuations

The domain of a continuation may be shrunk via `cont.bind`. This
instruction provides a way to partially apply a given
continuation. This facility turns out to be important in practice due
to the block and type structure of Wasm as in order to return a
continuation from a block, all branches within the block must agree on
the type of continuation. By using `cont.bind`, one can
programmatically ensure that the branches within a block each return a
continuation with compatible type (the [Examples](#examples) section
provides several example usages of `cont.bind`).


```wat
cont.bind $ct : [tp* (cont ([tp* tp'*] -> [t2*]))] -> [(cont ([tp'*] -> [t2*]))]
```

The instruction `cont.bind` binds the arguments of type `tp*` to the
continuation `$ct`, yielding a modified continuation which expects
fewer arguments. This instruction also consumes its continuation
argument, and yields a new continuation that can be supplied to either
`resume`,`resume_throw`, or `cont.bind`.

### Trapping Continuations

In order to ensure that control cannot be captured across language
boundaries, we provide an instruction for explicitly trapping attempts
at reifying stacks across language boundaries.

```wat
barrier $label bt instr* : [t1*] -> [t2*]
```

The `barrier` instruction is a block with label `$label`, block type
`bt = [t1*] -> [t2*]`, and whose body is the instruction sequence
given by `instr*`. Operationally, `barrier` may be viewed as a
"catch-all" handler, that handles any control tag by invoking a trap.

## Continuation Lifetime

### Producing Continuations

There are three different ways in which continuations are produced
(`cont.new,suspend,cont.bind`). A fresh continuation object is
allocated with `cont.new` and the current continuation is reused with
`suspend` and `cont.bind`.

The `cont.bind` instruction is directly analogous to the mildly
controversial `func.bind` instruction from the function references
proposal. However, whereas the latter necessitates the allocation of a
new closure, as continuations are single-shot no allocation is
necessary: all allocation happens when the original continuation is
created by preallocating one slot for each continuation argument.

### Consuming Continuations

There are three different ways in which continuations are consumed
(`resume,resume_throw,cont.bind`). A continuation is resumed with a
particular handler with `resume`. A continuation is aborted with
`resume_throw`. A continuation is partially applied with `cont.bind`.

In order to ensure that continuations are one-shot,
`resume,resume_throw,cont.bind` destructively modify the continuation
object such that any subsequent use of the same continuation object
will result in a trap.

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

## Implementation Strategies

### Stack cut'n'paste (TODO)

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
 |-----------------------|
 |                       |
 | ...                   |
 |                       |
 | (resume $h1 $c); |
>| $c = (cont.new $f)    |
 |                       |
 .                       .
 .                       .

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
 |                     |           |---------------------|
>| resume $h1 $c ------------>| $f()                |
 .                     .           .                     .
 .                     .           .                     .
                                   .                     .

```

Stack 1 maintains control after the creation of stack 2, and thus
execution continues on stack 1. The next instruction, `resume`
suspends stack 1 and transfers control to new stack 2. Before
transferring control, the instruction installs a delimiter `$h1` on
stack 1. The transfer of control reverses the parent-child link, such
that stack 2 now points back to stack 1. The instruction also installs
a delimiter on the parent

```ioke
      (stack 1)                         (stack 2)
       (active)
 |---------------------|
 |                     |
 | ...                 |
 |                     |                 (suspended)
 |                     |       ----|---------------------|
>| $h1                 |<-----/    | $f()                |
 .                     .           |                     |
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
 |                     |       ----|---------------------|
 | $h1                 |<-----/   >| $f()                |
 .                     .           |                     |
 .                     .           .                     .
 .                     .           .                     .
                                   .                     .
```

As execution continues on stack 2 it may eventually perform a
`suspend`, which will cause another transfer of
control. Supposing it invokes `suspend` with some `$tag` handled
by `$h1`, then stack 2 will transfer control back to stack 1.


```ioke
      (stack 1)                         (stack 2)
       (suspended)
 |---------------------|
 |                     |
 | ...                 |
 |                     |                 (active)
 |                     |       ----|---------------------|
 | $h1                 |<-----/    | ...                 |
 .                     .          >| suspend $tag   |
 .                     .           .                     .
 .                     .           .                     .
                                   .                     .
```

The suspension reverses the parent-child link again, and leaves behind
a "hole" on stack 2, that can be filled by an invocation of
`resume`.

```ioke
      (stack 1)                         (stack 2)
       (suspended)
 |---------------------|
 |                     |
 | ...                 |
 |                     |                 (active)
 |                     |       --->|---------------------|
>| $h1                 |------/    | ...                 |
 .                     .           | [ ]                 |
 .                     .           .                     .
 .                     .           .                     .
                                   .                     .
```



## FAQ

### Memory Management

The current proposal does not require a cycle-detecting garbage
collector as the linearity of continuations guarantees that there are
no cycles in continuation objects. In theory, we could do without any
automated memory management at all if we took seriously the idea that
failure to use a continuation constitutes a bug in the producer. In
practice, we expect that for many systems the only feasible way to
ensure that continuations are always used (or at least deallocated) is
to use some form of automated memory management, such as a reference
counting.

### Linear vs Constant Time Dispatch

The `suspend` instruction relies on traversing a stack of
handlers in order to find the appropriate handler, similarly to
exception handling. A potential problem is that this can incur a
linear runtime cost, especially if we think in terms of segmented
stacks, where `suspend` must search the active stack chain for a
suitable handler for its argument. Practical experience from Multicore
OCaml suggests that for critical use cases (async/await, lightweight
threads, actors, etc.) the depth of the handler stack tends to be
small so the cost of this linear traversal is negligible. Nonetheless,
future applications may benefit from constant-time dispatch. To enable
constant-time dispatch we would need to know the target stack a
priori, which might be acheived either by maintaining a shadow stack
or by extending `suspend` to explicitly target a named handler.

### Named Handlers

We can accommodate named handlers by introducing a new reference type
`handler t*`, which essentially is a unique prompt created by
executing a variant of the `resume` instruction and is passed to the
continuation:

```wat
  resume_with (event $tag $handler)* : [ t1* (cont $ft) ] -> [ t2* ]
  where:
   - $ft = [ (handler t2*) t1* ] -> [ t2* ]
```

The handler reference is similar to a prompt in a system of
multi-prompt continuations. However, since it is created fresh for
each handler, multiple activations of the same prompt cannot exist by
construction.

This instruction is complemented by an instruction for suspending to a
specific handler:

```wat
  suspend_to $tag : [ t1* (handler t3*) ] -> [ t2* ]
  where:
  - $tag : [ t1* ] -> [ t2* ]
```

If the handler is not currently active, e.g., because an outer handler
has been suspended, then this instruction would trap.

### Direct Switching

The current proposal uses the asymmetric suspend/resume pair of
primitives that is characteristic of effect handlers. It does not
include a symmetric way of switching to another continuation directly,
without going through a handler, and it is conceivable that the double
hop through a handler might involve unnecessary overhead for use cases
like lightweight threading.

Though there is currently no evidence that the double hop overhead is
significant in practice, if it does turn out to be important for some
applications then the current proposal can be extended with a more
symmetric `switch_to` primitive.

Given named handlers, it is possible to introduce a somewhat magic
instruction for switching directly to another continuation:

```wat
  cont.switch_to : [ t1* (cont $ft1) (handler t3*) ] -> [ t2* ]
  where:
   - $ft1 = [ (handler t3*) (cont $ft2) t1* ] -> [ t3* ]
   - $ft2 = [ t2* ] -> [ t3* ]
```

This behaves as if there was a built-in tag

```wat
  (tag Switch (param t1* (cont $ft1)) (result t3*))
```

with which the computation suspends to the handler, and the handler
implicitly handles this by resuming to the continuation argument,
thereby effectively switching to it in one step. Like `suspend_to`,
this would trap if the handler was not currently active.

The fact that the handler implicitly resumes, passing itself as a
handler to the target continuation, makes this construct behave like a
deep handler, which is slightly at odds with the rest of the proposal.

In addition to the handler, `switch_to` also passes the new
continuation to the target, which allows the target to `switch_to`
back to it in a symmetric fashion. Notably, in such a use case, `$ft1`
and `$ft2` would be the same type (and hence recursive).

In fact, symmetric switching need not necessarily be tied to named
handlers, since there could also be an indirect version with dynamic
handler lookup:

```wat
  cont.switch : [ t1* (cont $ft1) ] -> [ t2* ]
  where:
  - $ft1 = [ (cont $ft2) t1* ] -> [ t3* ]
  - $ft2 = [ t2* ] -> [ t3* ]
```

It seems undesirable that every handler implicitly handles the
built-in `Switch` tag, so this should be opt-in by a mode flag on the
resume instruction(s).

### Control/Prompt as an Alternative Basis

An alternative to typed continuations is to use more classical
delimited continuations via operators such as control/prompt and
shift/reset. As illustrated in the examples section, control/prompt
can be viewed as a special instance of the current proposal with a
single control tag `control` and a handler for each `prompt`. Thus
every non-local control flow abstraction has to be codified via a
single control tag, which makes static typing considerably more
difficult.

SL: The following is not really true: answer-type modification makes
the type system more expressive, but it's perfectly sound to consider
rules that preclude answer-type modification.

In order to preserve static type-safety, operators like shift/reset
and control/prompt require something like *answer-type modification*,
which would be a fairly profound addition to the Wasm type system
[Danvy&Filinski'89, Cong et al. '21].

### Tail-resumptive Handlers

SL: the business about constant-time dispatch is perhaps only relevant
for tail-resumptive handlers, as in the general case one has to
construct the continuation, which may take linear time anyway... but
maybe their exist more interesting representations continuation
representations that could support constant-time dispatch for
non-tail-resumptive handlers too.

A handler is said to be *tail-resumptive* if the handler invokes the
continuation in tail-position in every control tag clause. The
canonical example of a tail-resumptive handler is dynamic binding
(which can be useful to implement implicit parameters to
computations). The key insight is that the control tag clauses of a
tail-resumptive handler can be inlined at the control tag invocation
sites, because they does not perform any fancy control flow
manipulation, they simply "retrieve a value", as it were. The gain by
inlining the clause definitions is that computation need not spend
time constructing continuations.

The present iteration of this proposal does not include facilities for
identifying and inlining tail-resumptive handlers. None of the
critical use-cases requires such a facility. Nevertheless, it is
natural to envisage a future iteration of this proposal that includes
an extension for distinguishing tail-resumptive handlers.


### Multi-shot Continuations

Continuations in this proposal are *single-shot* (aka *linear*),
meaning that they must be invoked exactly once (though this is not
statically enforced). A continuation can be invoked either by resuming
it (with `resume`) or by aborting it (with `resume_throw`). Some
applications such as backtracking, probabilistic programming, and
process duplication exploit *multi-shot* continuations, but none of
the critical use cases require multi-shot continuations. Nevertheless,
it is natural to envisage a future iteration of this proposal that
includes support for multi-shot continuations by way of a continuation
clone instruction.

TODO: shallow vs deep

TODO: named handlers

TODO: first-class tags

TODO: preemption / asynchrony / interrupts

TODO: how do we interact with polymorphism?

TODO: parametric tags / existential types?

TODO: tag subtyping?

TODO: compare to asyncify?

TODO: compare to Wasm/k?

