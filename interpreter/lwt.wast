;; dynamic lightweight threads

;; interface to cooperative concurrency
(module $coop
  (type $proc (func))
  (event $yield (export "yield"))
  (event $spawn (export "spawn") (param (ref $proc)))
)
(register "coop")

(module $threads
  (type $proc (func))
  (type $cont (cont $proc))
  (event $yield (import "coop" "yield"))
  (event $spawn (import "coop" "spawn") (param (ref $proc)))

  (func $log (import "spectest" "print_i32") (param i32))

  (elem declare func $thread1 $thread2 $thread3)

  (func $main (export "main")
    (call $log (i32.const 0))
    (suspend $spawn (ref.func $thread1))
    (call $log (i32.const 1))
    (suspend $spawn (ref.func $thread2))
    (call $log (i32.const 2))
    (suspend $spawn (ref.func $thread3))
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
(register "threads")

(module $scheduler
  (type $proc (func))
  (type $cont (cont $proc))

  (event $yield (import "coop" "yield"))
  (event $spawn (import "coop" "spawn") (param (ref $proc)))

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
        (block $on_spawn (result (ref $proc) (ref $cont))
          (resume (event $yield $on_yield) (event $spawn $on_spawn)
            (call $dequeue)
          )
          (br $l)  ;; thread terminated
        ) ;;   $on_spawn (result (ref $proc) (ref $cont))
        (call $enqueue)                         ;; continuation of current thread
        (call $enqueue (cont.new (type $cont))) ;; new thread
        (br $l)
      )
      ;;     $on_yield (result (ref $cont))
      (call $enqueue) ;; continuation of current thread
      (br $l)
    )
  )
)

(register "scheduler")

(module
  (type $proc (func))
  (func $scheduler (import "scheduler" "scheduler") (param $main (ref $proc)))

  (func $log (import "spectest" "print_i32") (param i32))

  (func $main (import "threads" "main"))

  (elem declare func $main)

  (func (export "run")
    (call $log (i32.const -1))
    (call $scheduler (ref.func $main))
    (call $log (i32.const -2))
  )
)

(assert_return (invoke "run"))
