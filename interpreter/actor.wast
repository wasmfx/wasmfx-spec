;; Actors via cooperative concurrency

;; interface to cooperative concurrency
(module $coop
  (type $proc (func))
  (event $yield (export "yield"))
  (event $fork (export "fork") (param (ref $proc)))
)
(register "coop")

;; actors implemented using cooperative concurrency primitives
(module $actor
  (type $proc (func))
  (type $cont (cont $proc))

  (func $log (import "spectest" "print_i32") (param i32))

  (event $yield (import "coop" "yield"))
  (event $fork (import "coop" "fork") (param (ref $proc)))

  (exception $too-many-mailboxes)
  (exception $too-many-messages)

  (type $iproc (func (param i32)))
  (type $icont (cont $iproc))

  ;; Stupid implementation of mailboxes that raises an exception if
  ;; there are too many mailboxes or if more than one messages is sent
  ;; to any given mailbox.
  ;;
  ;; Sufficient for the simple chain example.

  ;; -1 means empty

  (memory 10000)

  (global $msize (mut i32) (i32.const 0))

  (func $empty-mb (param $mb i32) (result i32)
    (local $offset i32)
    (local.set $offset (i32.mul (local.get $mb) (i32.const 4)))
    (i32.eq (i32.load (local.get $offset)) (i32.const -1))
  )

  (func $new-mb (result i32)
     (local $mb i32)

     (if (i32.ge_u (i32.mul (global.get $msize) (i32.const 4))
                   (i32.sub (i32.const 10000) (i32.const 4)))
         (then (throw $too-many-mailboxes))
     )

     (local.set $mb (global.get $msize))
     (global.set $msize (i32.add (global.get $msize) (i32.const 1)))
     (return (local.get $mb))
  )

  (func $send-to-mb (param $v i32) (param $mb i32)
    (local $offset i32)
    (local.set $offset (i32.mul (local.get $mb) (i32.const 4)))
    (if (call $empty-mb (local.get $mb))
      (then (i32.store (local.get $offset) (local.get $v)))
      (else (throw $too-many-messages))
    )
  )

  (func $recv-from-mb (param $mb i32) (result i32)
    (local $v i32)
    (local $offset i32)
    (local.set $offset (i32.mul (local.get $mb) (i32.const 4)))
    (local.set $v (i32.load (local.get $offset)))
    (i32.store (local.get $offset) (i32.const -1))
    (local.get $v)
  )

  ;; actor interface
  (event $self (export "self") (result i32))
  (event $spawn (export "spawn") (param (ref $proc)) (result i32))
  (event $send (export "send") (param i32 i32))
  (event $recv (export "recv") (result i32))

  (elem declare func $act-res $act-nullary $recv-againf)

  ;; Rather than having a loop in the recv clause, it would be nice if
  ;; we could implement blocking by reinvoking recv with the original
  ;; handler. This is a common pattern nicely supported by shallow but
  ;; not deep handlers. However, it would require composing the new
  ;; reinvoked recv with the continuation. This can already be
  ;; simulated (inefficiently, perhaps) by resuming the continuation
  ;; with an identity handler and then building a new
  ;; continuation. Might an instruction for composing or extending
  ;; continuations be palatable / desirable?
  ;;
  ;; (Continuation composition / extension generalises partial
  ;; application of continuations - so also provides a way of avoiding
  ;; the kind of code duplication we see in $act-res and
  ;; $act-nullary.)

  ;; compose recv with an existing continuation
  (func $recv-againf (param $ik (ref $icont))
    (local $res i32)
    (suspend $recv)
    (local.set $res)
    (resume (local.get $res) (local.get $ik))
  )

  (func $recv-again (param $ik (ref $icont)) (result (ref $cont))
    (cont.new (type $cont) (func.bind (type $proc) (local.get $ik) (ref.func $recv-againf)))
  )

  ;; resume with $ik applied to $res
  (func $act-res (param $mine i32) (param $res i32) (param $ik (ref $icont))
    (block $on_self (result (ref $icont))
      (block $on_spawn (result (ref $proc) (ref $icont))
        (block $on_send (result i32 i32 (ref $cont))
          (block $on_recv (result (ref $icont))
             ;; this should really be a tail call to the continuation
             ;; do we need a 'return_resume' operator?
             (resume (event $self $on_self)
                     (event $spawn $on_spawn)
                     (event $send $on_send)
                     (event $recv $on_recv)
                     (local.get $res) (local.get $ik)
             )
             (return)
          ) ;; recv
          (let (local $ik (ref $icont))
            (loop $l
              (if (call $empty-mb (local.get $mine))
                  (then (suspend $yield)
                        (br $l))
              )
            )
            ;; alternative version - reinvoke receive
            ;;
            ;; (if (call $empty-mb (local.get $mine))
            ;;     (then (suspend $yield)
            ;;           (return_call_ref (local.get $mine) (call $recv-again (local.get $ik)) (ref.func $act-nullary)))
            ;; )
            (call $recv-from-mb (local.get $mine))
            (local.set $res)
            (return_call_ref (local.get $mine) (local.get $res) (local.get $ik) (ref.func $act-res)))
          (unreachable)
        ) ;; send
        (let (param i32 i32) (local $k (ref $cont))
          (call $send-to-mb)
          (return_call_ref (local.get $mine) (local.get $k) (ref.func $act-nullary)))
        (unreachable)
      ) ;; spawn
      (let (local $you (ref $proc)) (local $ik (ref $icont))
        (call $new-mb)
        (local.set $res)
        (suspend $fork (func.bind (type $proc) (local.get $res)
                                  (cont.new (type $cont) (local.get $you)) (ref.func $act-nullary)))
        (return_call_ref (local.get $mine) (local.get $res) (local.get $ik) (ref.func $act-res))
      )
      (unreachable)
    ) ;; self
    (let (local $ik (ref $icont))
      (return_call_ref (local.get $mine) (local.get $mine) (local.get $ik) (ref.func $act-res))
    )
    (unreachable)
  )

  ;; resume with nullary continuation
  (func $act-nullary (param $mine i32) (param $k (ref $cont))
    (local $res i32)
    (block $on_self (result (ref $icont))
      (block $on_spawn (result (ref $proc) (ref $icont))
        (block $on_send (result i32 i32 (ref $cont))
          (block $on_recv (result (ref $icont))
             ;; this should really be a tail call to the continuation
             ;; do we need a 'return_resume' operator?
             (resume (event $self $on_self)
                     (event $spawn $on_spawn)
                     (event $send $on_send)
                     (event $recv $on_recv)
                     (local.get $k)
             )
             (return)
          ) ;; recv
          (let (local $ik (ref $icont))
            (loop $l
              (if (call $empty-mb (local.get $mine))
                  (then (suspend $yield)
                        (br $l))
              )
            )
            (call $recv-from-mb (local.get $mine))
            (local.set $res)
            (return_call_ref (local.get $mine) (local.get $res) (local.get $ik) (ref.func $act-res)))
          (unreachable)
        ) ;; send
        (let (param i32 i32) (local $k (ref $cont))
          (call $send-to-mb)
          (return_call_ref (local.get $mine) (local.get $k) (ref.func $act-nullary)))
        (unreachable)
      ) ;; spawn
      (let (local $you (ref $proc)) (local $ik (ref $icont))
        (call $new-mb)
        (local.set $res)
        (suspend $fork (func.bind (type $proc) (local.get $res)
                                  (cont.new (type $cont) (local.get $you)) (ref.func $act-nullary)))
        (return_call_ref (local.get $mine) (local.get $res) (local.get $ik) (ref.func $act-res))
      )
      (unreachable)
    ) ;; self
    (let (local $ik (ref $icont))
      (return_call_ref (local.get $mine) (local.get $mine) (local.get $ik) (ref.func $act-res))
    )
    (unreachable)
  )

  (func $act (export "act") (param $f (ref $proc))
    (memory.fill (i32.const 0) (i32.const -1) (i32.const 10000))
    (call $act-nullary (call $new-mb) (cont.new (type $cont) (local.get $f)))
  )
)
(register "actor")


;; a simple scheduler
(module $scheduler
  (type $proc (func))
  (type $cont (cont $proc))

  (event $yield (import "coop" "yield"))
  (event $fork (import "coop" "fork") (param (ref $proc)))

  ;; Table as simple queue (keeping it simple, no ring buffer)
  (table $queue 0 (ref null $cont))
  (global $qdelta i32 (i32.const 10))
  (global $qback (mut i32) (i32.const 0))
  (global $qfront (mut i32) (i32.const 0))

  (func $queue-empty (result i32)
    (i32.eq (global.get $qfront) (global.get $qback))
  )

  (func $dequeue (result (ref null $cont))
    (local $i i32)
    (if (call $queue-empty)
      (then (return (ref.null $cont)))
    )
    (local.set $i (global.get $qfront))
    (global.set $qfront (i32.add (local.get $i) (i32.const 1)))
    (table.get $queue (local.get $i))
  )

  (func $enqueue (param $k (ref $cont))
    ;; Check if queue is full
    (if (i32.eq (global.get $qback) (table.size $queue))
      (then
        ;; Check if there is enough space in the front to compact
        (if (i32.lt_u (global.get $qfront) (global.get $qdelta))
          (then
            ;; Space is below threshold, grow table instead
            (drop (table.grow $queue (ref.null $cont) (global.get $qdelta)))
          )
          (else
            ;; Enough space, move entries up to head of table
            (global.set $qback (i32.sub (global.get $qback) (global.get $qfront)))
            (table.copy $queue $queue
              (i32.const 0)         ;; dest = new front = 0
              (global.get $qfront)  ;; src = old front
              (global.get $qback)   ;; len = new back = old back - old front
            )
            (table.fill $queue      ;; null out old entries to avoid leaks
              (global.get $qback)   ;; start = new back
              (ref.null $cont)      ;; init value
              (global.get $qfront)  ;; len = old front = old front - new front
            )
            (global.set $qfront (i32.const 0))
          )
        )
      )
    )
    (table.set $queue (global.get $qback) (local.get $k))
    (global.set $qback (i32.add (global.get $qback) (i32.const 1)))
  )

  (elem declare func $coop-kt $coop-tk $coop-ykt $coop-ytk)

  ;; * coop-kt and coop-tk don't yield on encountering a fork
  ;;   - coop-kt runs the continuation, queuing up the new thread for later
  ;;   - coop-tk runs the new thread first, queuing up the continuation for later
  ;; * coop-ykt and coop-ytk do yield on encountering a fork
  ;;   - coop-ykt runs the continuation, queuing up the new thread for later
  ;;   - coop-ytk runs the new thread first, queuing up the continuation for later

  ;; no yield on fork, continuation first
  (func $coop-kt (param $r (ref null $cont))
    (if (ref.is_null (local.get $r)) (then (return)))
    (block $on_yield (result (ref $cont))
      (block $on_fork (result (ref $proc) (ref $cont))
        (resume (event $yield $on_yield) (event $fork $on_fork) (local.get $r))
        (call $dequeue)
        (return_call_ref (ref.func $coop-kt))
      )
      ;; fork
      (let (param (ref $proc)) (result (ref $cont)) (local $r (ref $cont))
      (cont.new (type $cont))
      (call $enqueue)
      (local.get $r)
      (return_call_ref (ref.func $coop-kt)))
    )
    ;; yield
    (call $enqueue)
    (call $dequeue)
    (return_call_ref (ref.func $coop-kt))
  )

  ;; no yield on fork, new thread first
  (func $coop-tk (param $r (ref null $cont))
    (if (ref.is_null (local.get $r)) (then (return)))
    (block $on_yield (result (ref $cont))
      (block $on_fork (result (ref $proc) (ref $cont))
        (resume (event $yield $on_yield) (event $fork $on_fork) (local.get $r))
        (call $dequeue)
        (return_call_ref (ref.func $coop-tk))
      )
      ;; fork
      (call $enqueue)
      (return_call_ref (cont.new (type $cont)) (ref.func $coop-tk))
    )
    ;; yield
    (call $enqueue)
    (call $dequeue)
    (return_call_ref (ref.func $coop-tk))
  )

  ;; yield on fork, continuation first
  (func $coop-ykt (param $r (ref null $cont))
    (if (ref.is_null (local.get $r)) (then (return)))
    (block $on_yield (result (ref $cont))
      (block $on_fork (result (ref $proc) (ref $cont))
        (resume (event $yield $on_yield) (event $fork $on_fork) (local.get $r))
        (call $dequeue)
        (return_call_ref (ref.func $coop-ykt))
      )
      ;; fork
      (call $enqueue)
      (cont.new (type $cont))
      (call $enqueue)
      (return_call_ref (call $dequeue) (ref.func $coop-ykt))
    )
    ;; yield
    (call $enqueue)
    (call $dequeue)
    (return_call_ref (ref.func $coop-ykt))
  )

  ;; yield on fork, new thread first
  (func $coop-ytk (param $r (ref null $cont))
    (if (ref.is_null (local.get $r)) (then (return)))
    (block $on_yield (result (ref $cont))
      (block $on_fork (result (ref $proc) (ref $cont))
        (resume (event $yield $on_yield) (event $fork $on_fork) (local.get $r))
        (call $dequeue)
        (return_call_ref (ref.func $coop-ytk))
      )
      ;; fork
      (let (param (ref $proc)) (local $k (ref $cont))
        (cont.new (type $cont))
        (call $enqueue)
        (call $enqueue (local.get $k))
        (return_call_ref (call $dequeue) (ref.func $coop-ytk))
      )
      (unreachable)
    )
    ;; yield
    (call $enqueue)
    (call $dequeue)
    (return_call_ref (ref.func $coop-ytk))
  )

  (func $scheduler (export "scheduler") (param $main (ref $proc))
     (call $coop-tk (cont.new (type $cont) (local.get $main)))
  )
)
(register "scheduler")

;; composing the actor and scheduler handlers together
(module $actor-scheduler
  (type $proc (func))
  (type $procproc (func (param (ref $proc))))

  (elem declare func $act $scheduler $comp)

  (func $act (import "actor" "act") (param $f (ref $proc)))
  (func $scheduler (import "scheduler" "scheduler") (param $main (ref $proc)))

  (func $comp (param $h (ref $procproc)) (param $g (ref $procproc)) (param $f (ref $proc))
    (call_ref (func.bind (type $proc) (local.get $f) (local.get $g)) (local.get $h))
  )

  (func $compose (param $h (ref $procproc)) (param $g (ref $procproc)) (result (ref $procproc))
    (func.bind (type $procproc) (local.get $h) (local.get $g) (ref.func $comp))
  )

  (func $run-actor (export "run-actor") (param $f (ref $proc))
    (call_ref (local.get $f) (call $compose (ref.func $scheduler) (ref.func $act)))
  )
)
(register "actor-scheduler")

;; a simple example - pass a message through a chain of processes
(module $chain
  (type $proc (func))

  (event $self (import "actor" "self") (result i32))
  (event $spawn (import "actor" "spawn") (param (ref $proc)) (result i32))
  (event $send (import "actor" "send") (param i32 i32))
  (event $recv (import "actor" "recv") (result i32))

  (elem declare func $next $spawnMany)

  (func $log (import "spectest" "print_i32") (param i32))

  (func $next (param $p i32)
    (local $s i32)
    (local.set $s (suspend $recv))
    (call $log (i32.const -1))
    (suspend $send (local.get $s) (local.get $p))
  )

  (func $spawnMany (param $p i32) (param $n i32)
    (if (i32.eqz (local.get $n))
      (then (suspend $send (i32.const 42) (local.get $p))
            (return))
      (else (return_call_ref (suspend $spawn (func.bind (type $proc) (local.get $p) (ref.func $next)))
                             (i32.sub (local.get $n) (i32.const 1))
                             (ref.func $spawnMany)))

    )
  )

  ;; send the message 42 through a chain of n processes
  (func $chain (export "chain") (param $n i32)
    (local $s i32)
    (suspend $self)
    (local.get $n)
    (call $spawnMany)
    (local.set $s (suspend $recv))
    (call $log (local.get $s))
  )
)
(register "chain")

(module
  (type $proc (func))

  (elem declare func $chain)

  (func $run-actor (import "actor-scheduler" "run-actor") (param $f (ref $proc)))
  (func $chain (import "chain" "chain") (param $n i32))

  (func $run-chain (export "run-chain") (param $n i32)
    (call $run-actor (func.bind (type $proc) (local.get $n) (ref.func $chain)))
  )
)

(assert_return (invoke "run-chain" (i32.const 64)))
