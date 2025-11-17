
; libcore.asm - Biblioteca de primitives para VentureOS Kernel
; NASM x86_64
BITS 64
DEFAULT REL

section .data
align 8
; GDT
gdt_start:
    dq 0
    dq 0x00AF9A000000FFFF    ; code
    dq 0x00AF92000000FFFF    ; data
gdt_end:
gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dq gdt_start

; IDT (simples)
align 16
idt_table: times 256 dq 0
idt_descriptor:
    dw 256*16 - 1
    dq idt_table

section .bss
align 4096
pml4_table: resq 512
pdpt_table: resq 512
pd_table:   resq 512
pt_table:   resq 512

align 16
heap_base: resq 1

; task infrastructure (cooperativa simples)
align 8
task_sp:    resq 8      ; suporta até 8 tasks
task_state: resb 8
task_count: resb 1
current_task: dq 0

section .text
global gdt_setup
global enable_long_mode
global init_paging_minimal
global init_idt_and_handlers
global init_pic
global init_pit
global init_keyboard
global init_allocator
global kmalloc
global create_task
global scheduler_start
global yield_cpu
global panic

; ----------------------
; gdt_setup - carrega GDT e configura segmentos (64-bit selectors)
; ----------------------
gdt_setup:
    lea rax, [rel gdt_descriptor]
    lgdt [rax]
    ; set data selectors (0x10) - safe em long mode
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax
    ret

; ----------------------
; enable_long_mode - ativa EFER.LME e faz far jump para 64-bit
; assume já em protected mode com CR0.PE set
; ----------------------
enable_long_mode:
    ; set EFER.LME
    mov ecx, 0xC0000080
    rdmsr
    or eax, 1 << 8
    wrmsr

    ; set CR4.PAE
    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax

    ; carregar CR3 (assume init_paging_minimal preencheu pml4_table)
    lea rax, [rel pml4_table]
    mov cr3, rax

    ; enable paging (CR0.PG)
    mov eax, cr0
    or eax, 1 << 31
    mov cr0, eax

    ; far jump para selector 0x08 (code) e label long_entry
    pushq 0x08
    lea rax, [rel long_entry]
    push rax
    lretq
long_entry:
    ret

; ----------------------
; init_paging_minimal - constroi PML4/PDPT/PD/PT identity map para 0..4MB
; ----------------------
init_paging_minimal:
    ; limpa tabelas
    lea rdi, [rel pml4_table]
    xor rax, rax
    mov rcx, 512
1:
    mov qword [rdi], rax
    add rdi, 8
    loop 1b
    ; link pml4 -> pdpt -> pd -> pt
    mov rax, (pdpt_table) | 0x03
    mov [pml4_table], rax
    mov rax, (pd_table) | 0x03
    mov [pdpt_table], rax
    mov rax, (pt_table) | 0x03
    mov [pd_table], rax
    ; preencher pt com identity pages (só as primeiras páginas)
    mov rcx, 1024  ; cobre ~4MB (1024 * 4KB = 4MB)
    xor rbx, rbx
    lea rdi, [rel pt_table]
2:
    mov rax, rbx
    or rax, 0x83  ; present | writable | user
    mov [rdi], rax
    add rdi, 8
    add rbx, 0x1000
    loop 2b
    ret

; ----------------------
; IDT e handlers (stubs) - instala vetores básicos e habilita interrupts
; ----------------------
init_idt_and_handlers:
    lea rax, [rel idt_descriptor]
    lidt [rax]
    ; aqui geralmente set_idt_entry para IRQ0/1...
    ; deixamos handlers externos (user pode sobrescrever)
    sti
    ret

; ----------------------
; PIC remap e máscara
; ----------------------
init_pic:
    ; ICW1
    mov al, 0x11
    out 0x20, al
    out 0xA0, al
    ; ICW2: offsets 0x20/0x28
    mov al, 0x20
    out 0x21, al
    mov al, 0x28
    out 0xA1, al
    ; ICW3
    mov al, 0x04
    out 0x21, al
    mov al, 0x02
    out 0xA1, al
    ; ICW4
    mov al, 0x01
    out 0x21, al
    out 0xA1, al
    ; mask all except PIT/keyboard
    mov al, 0xFC
    out 0x21, al
    mov al, 0xFF
    out 0xA1, al
    ret

; ----------------------
; PIT init - simple rate generator
; ----------------------
init_pit:
    mov al, 0x34
    out 0x43, al
    mov ax, 1193
    mov dx, ax
    out 0x40, al
    mov al, ah
    out 0x40, al
    ret

; ----------------------
; keyboard init - unmask keyboard irq
; ----------------------
init_keyboard:
    in al, 0x21
    and al, 0xFD
    out 0x21, al
    ret

; ----------------------
; allocator (bump) - init_allocator / kmalloc
; ----------------------
init_allocator:
    mov qword [heap_base], 0x200000   ; base do heap (2MB)
    ret

kmalloc:
    ; rdi = size, retorna rax = ptr
    mov rax, [heap_base]
    mov rcx, rdi
    add rax, rcx
    ; alinhar 8
    add rax, 7
    and rax, -8
    mov rdx, rax
    sub rdx, rdi
    mov [heap_base], rax
    mov rax, rdx
    ret

; ----------------------
; task / scheduler (cooperativo simples)
; create_task(index, entry)
; scheduler_start() - jump para primeira task
; yield_cpu() - salva/restore minimal via RSP swap
; ----------------------
create_task:
    ; rdi = index, rsi = entry
    mov rax, task_sp
    mov rcx, rdi
    imul rcx, 8
    add rax, rcx
    ; compute stack top: stack area we leave flexible - here usamos kmalloc para stack
    mov rdi, 0x4000
    call kmalloc
    add rax, 0x4000
    mov [rax], 0    ; placeholder
    mov [task_sp + rcx], rax
    mov byte [task_state + rdi], 1
    ; inicializa frame: push rflags(0x200) ; push rip(entry)
    sub rax, 8
    mov qword [rax], 0x200
    sub rax, 8
    mov qword [rax], rsi
    mov [task_sp + rcx], rax
    ret

scheduler_start:
    mov qword [current_task], 0
    call schedule_switch_to_current
    ret

schedule_switch_to_current:
    mov rax, [current_task]
    mov rsp, [task_sp + rax*8]
    ret

yield_cpu:
    ; simples: increment current, wrap by task_count
    mov rax, [current_task]
    movzx rcx, byte [task_count]
    add rax, 1
    cmp rax, rcx
    jb .ok
    xor rax, rax
.ok:
    mov [current_task], rax
    call schedule_switch_to_current
    ret

panic:
    cli
    hlt
    jmp panic




; kernel.asm - bootstrap minimal usando libcore.asm
BITS 32
DEFAULT REL
; multiboot header opcional omitido pra simplificar (supondo GRUB)

extern gdt_setup
extern enable_long_mode
extern init_paging_minimal
extern init_allocator
extern init_pic
extern init_pit
extern init_keyboard
extern init_idt_and_handlers
extern create_task
extern scheduler_start
extern panic

section .text
global kernel_entry
kernel_entry:
    ; assume carregador colocou CPU em protected mode e CR0.PE=1
    ; carregar GDT e preparar
    call gdt_setup

    ; configurar paginação básica
    call init_paging_minimal

    ; habilitar long mode (faz o far jump internamente)
    call enable_long_mode

    ; agora em 64-bit
    ; chamar inicializadores que vêm da libcore
    call init_allocator
    call init_pic
    call init_pit
    call init_keyboard
    call init_idt_and_handlers

    ; criar tasks demo (2 tasks) - index 0 e 1 apontando pra funções internas
    ; aqui definimos duas rotinas simples em labels locais
    lea rsi, [rel task1_entry]
    mov rdi, 0
    call create_task
    lea rsi, [rel task2_entry]
    mov rdi, 1
    call create_task

    ; set task_count = 2
    mov byte [rel task_count], 2

    ; start scheduler
    call scheduler_start

    ; se cair aqui, panic
    call panic

task1_entry:
    ; loop simples: chama yield em ciclo
.t1:
    ; exemplo de "trabalho"
    call yield_cpu
    jmp .t1

task2_entry:
.t2:
    call yield_cpu
    jmp .t2


ENTRY(kernel_entry)
SECTIONS
{
  . = 0x100000;
  .text : { *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }
  .bss : { *(.bss*) }
}

nasm -f elf64 libcore.asm -o libcore.o
nasm -f elf64 kernel.asm -o kernel.o
ld -T linker.ld libcore.o kernel.o -o ventureos.elf
