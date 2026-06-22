; ARM64 Assembly - Apple Watch Demo
; Fibonacci sequence calculation

.section __TEXT,__text
.global _main
.align 2

_main:
    mov x0, #0          ; a = 0
    mov x1, #1          ; b = 1
    mov x2, #10         ; loop counter

loop:
    cmp x2, #0          ; check counter
    b.le done           ; if counter <= 0, exit

    add x3, x0, x1      ; c = a + b
    mov x0, x1          ; a = b
    mov x1, x3          ; b = c

    sub x2, x2, #1      ; counter--
    b loop              ; repeat

done:
    mov x0, #0          ; return 0
    mov x16, #0x20001   ; exit syscall
    svc #0x80           ; syscall
