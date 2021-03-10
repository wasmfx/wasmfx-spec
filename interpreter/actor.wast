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

  (type $iproc (func (param i32)))
  (type $icont (cont $iproc))

  ;; dummy implementation of mailboxes
  ;;
  ;; to avoid the dynamic memory managment required to actually
  ;; implement mailboxes all messages are multiplexed to a single
  ;; global!
  ;;
  ;; This gives completely the wrong semantics, but at least the
  ;; functions have the correct type signatures!

  (global $the-mb (mut i32) (i32.const 0))

  (func $new-mb (result i32)
     (i32.const 0)
  )

  (func $send-to-mb (param $v i32) (param $mb i32)
    (global.set $the-mb (local.get $v))
  )

  (func $empty-mb (param $mb i32) (result i32)
    (i32.eqz (global.get $the-mb))
  )

  (func $recv-from-mb (param $mb i32) (result i32)
    (global.get $the-mb)
    (global.set $the-mb (i32.const 0))
  )

  (event $self (export "self") (result i32))
  (event $spawn (export "spawn") (param (ref $proc)) (result i32))
  (event $send (export "send") (param i32 i32))
  (event $recv (export "recv") (result i32))

  (elem declare func $act-res $act-nullary)

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
          (call $log (i32.const 14))
          (local.set $ik)
          (if (call $empty-mb (local.get $mine))
              (then (suspend $yield)
        (call $log (i32.const 55))
                    (suspend $recv)
        (call $log (i32.const 66))
                    (local.set $res)
                    (return_call_ref (local.get $mine) (local.get $res) (local.get $ik) (ref.func $act-res)))
          )
          (call $recv-from-mb (local.get $mine))
          (local.set $res)
          (return_call_ref (local.get $mine) (local.get $res) (local.get $ik) (ref.func $act-res))
        ) ;; send
        (call $log (i32.const 13))
        (let (param i32 i32) (local $k (ref $cont))
          (call $send-to-mb)
          (return_call_ref (local.get $mine) (local.get $k) (ref.func $act-nullary)))
        (unreachable)
      ) ;; spawn
      (call $log (i32.const 12))
      (local.set $ik)
      (let (local $you (ref $proc))
        (call $new-mb)
        (local.set $res)
        (suspend $fork (func.bind (type $proc) (local.get $res)
                                  (cont.new (type $cont) (local.get $you)) (ref.func $act-nullary)))
      )
      (return_call_ref (local.get $mine) (local.get $res) (local.get $ik) (ref.func $act-res))
    ) ;; self
    (call $log (i32.const 11))
    (local.set $ik)
    (return_call_ref (local.get $mine) (local.get $mine) (local.get $ik) (ref.func $act-res))
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
          (call $log (i32.const 24))
          (let (local $ik (ref $icont))
            (if (call $empty-mb (local.get $mine))
                  (then (suspend $yield)
        (call $log (i32.const 77))
                        (suspend $recv)
        (call $log (i32.const 88))
                        (local.set $res)
                        (return_call_ref (local.get $mine) (local.get $res) (local.get $ik) (ref.func $act-res)))
            )
            (call $recv-from-mb (local.get $mine))
            (local.set $res)
            (return_call_ref (local.get $mine) (local.get $res) (local.get $ik) (ref.func $act-res)))
          (unreachable)
        ) ;; send
        (call $log (i32.const 23))
        (local.set $k)
        (call $send-to-mb)
        (return_call_ref (local.get $mine) (local.get $k) (ref.func $act-nullary))
      ) ;; spawn
      (call $log (i32.const 22))
      (let (local $you (ref $proc)) (local $ik (ref $icont))
        (call $new-mb)
        (local.set $res)
        (suspend $fork (func.bind (type $proc) (local.get $res)
                                  (cont.new (type $cont) (local.get $you)) (ref.func $act-nullary)))
        (return_call_ref (local.get $mine) (local.get $res) (local.get $ik) (ref.func $act-res))
      )
      (unreachable)
    ) ;; self
    (call $log (i32.const 21))
    (let (local $ik (ref $icont))
      (return_call_ref (local.get $mine) (local.get $mine) (local.get $ik) (ref.func $act-res))
    )
    (unreachable)
  )

  (func $act (export "act") (param $f (ref $proc))
    (call $act-nullary (i32.const 0) (cont.new (type $cont) (local.get $f)))
  )
)
(register "actor")


;; a simple scheduler
(module $scheduler
  (type $proc (func))
  (type $cont (cont $proc))

  (func $log (import "spectest" "print_i32") (param i32))

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

  (func $scheduler (export "scheduler") (param $main (ref $proc))
    (call $enqueue (cont.new (type $cont) (local.get $main)))
    (loop $l
      (if (call $queue-empty) (then (return)))
      (block $on_yield (result (ref $cont))
        (block $on_fork (result (ref $proc) (ref $cont))
          (resume (event $yield $on_yield) (event $fork $on_fork)
            (call $dequeue)
          )
          (br $l)  ;; thread terminated
        )
        ;; on $fork, proc and cont on stack
        (call $log (i32.const 32))
        (call $enqueue)                          ;; continuation of old thread
        (call $enqueue (cont.new (type $cont)))  ;; new thread
        (br $l)
      )
      ;; on $yield, cont on stack
      (call $log (i32.const 31))
      (call $enqueue)
      (br $l)
    )
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
    (call $log (i32.const 0))
    (if (i32.eqz (local.get $n))
      (then (suspend $send (i32.const 42) (local.get $p))
            (return)))
    ;; else
    (return_call_ref (suspend $spawn (func.bind (type $proc) (local.get $p) (ref.func $next)))
                     (i32.sub (local.get $n) (i32.const 1))
                     (ref.func $spawnMany))

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

;; currently this fails due to an unhandled event "recv"
;;
;; it looks like the inner handler may be being discarded when an
;; event bubbles up to an outer handler
(assert_return (invoke "run-chain" (i32.const 2)))
