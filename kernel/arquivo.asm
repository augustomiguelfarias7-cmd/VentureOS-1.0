; =============================================================
;              VentureOS Kernel - Arquivo Único
;           Desenvolvido para Augusto 😄🔥 sem simulação
; =============================================================

[org 0x7C00]
bits 16

; -------------------------------------------------------------
; Bootloader real (entra protegido e salta para o kernel)
; -------------------------------------------------------------
start:
    cli
    xor ax, ax
    mov ds, ax
    mov ss, ax
    mov sp, 0x7C00

    mov si, boot_msg
    call print_16

    call enable_a20

    lgdt [gdt_descriptor]

    mov eax, cr0
    or eax, 1
    mov cr0, eax

    jmp 0x08:pmode_enter


boot_msg db "VentureOS Bootloader iniciado...",0


; -------------------------------------------------------------
; Rotina de impressão no modo real
; -------------------------------------------------------------
print_16:
    mov ah,0x0E
.lp:
    lodsb
    cmp al,0
    je .done
    int 0x10
    jmp .lp
.done:
    ret

; -------------------------------------------------------------
; Habilita A20 (necessário para 32-bit real)
; -------------------------------------------------------------
enable_a20:
    in al,0x92
    or al,00000010b
    out 0x92,al
    ret

; =============================================================
;            ENTRA NO MODO PROTEGIDO (32 BITS)
; =============================================================
bits 32
pmode_enter:
    mov ax,0x10
    mov ds,ax
    mov ss,ax
    mov es,ax
    mov fs,ax
    mov gs,ax

    mov esp,0x9FC00

    call clear_screen
    call idt_install
    call pic_remap
    call pit_init
    call keyboard_init

    sti

    jmp kernel_main


; =============================================================
;                           GDT
; =============================================================
gdt_start:
    dq 0                    ; null
    dq 0x00CF9A000000FFFF  ; code
    dq 0x00CF92000000FFFF  ; data
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start


; =============================================================
;                 Limpa tela (modo texto real)
; =============================================================
clear_screen:
    mov edi,0xB8000
    mov ecx,80*25
    mov ax,0x0720
rep stosw
    ret


; =============================================================
;                           IDT
; =============================================================
idt_table:
    times 256 dq 0

idt_descriptor:
    dw (idt_table_end - idt_table - 1)
    dd idt_table
idt_table_end:

make_idt_entry:
    ; edi = entry addr, eax = handler, bl = flags
    mov [edi], ax
    shr eax,16
    mov [edi+6], ax
    mov byte [edi+5], bl
    mov word [edi+2], 0x08
    ret


; -------------------------------------------------------------
; Instala IDT completa
; -------------------------------------------------------------
idt_install:
    lea edi,[idt_table]

    mov eax,irq0
    mov bl,0x8E
    call make_idt_entry

    mov eax,irq1
    mov bl,0x8E
    call make_idt_entry+8

    lidt [idt_descriptor]
    ret


; =============================================================
;                       PIC REMAP
; =============================================================
pic_remap:
    mov al,0x11
    out 0x20,al
    out 0xA0,al

    mov al,0x20
    out 0x21,al
    mov al,0x28
    out 0xA1,al

    mov al,0x04
    out 0x21,al
    mov al,0x02
    out 0xA1,al

    mov al,0x01
    out 0x21,al
    out 0xA1,al

    mov al,11111100b
    out 0x21,al
    mov al,11111111b
    out 0xA1,al
    ret


; =============================================================
;                         PIT (Timer)
; =============================================================
pit_init:
    mov al,0x36
    out 0x43,al
    mov ax,1193
    out 0x40,al
    mov al,ah
    out 0x40,al
    ret


; =============================================================
;                Teclado (IRQ1) — básico
; =============================================================
keyboard_init:
    in al,0x21
    and al,11111101b
    out 0x21,al
    ret


; =============================================================
;                      Rotinas IRQ
; =============================================================
irq0:
    pusha

    ; contador simples na tela
    mov eax,[ticks]
    inc eax
    mov [ticks],eax

    call print_tick

    popa
    mov al,0x20
    out 0x20,al
    iret

irq1:
    pusha
    in al,0x60
    mov [last_key],al
    popa
    mov al,0x20
    out 0x20,al
    iret


ticks dd 0
last_key db 0


; -------------------------------------------------------------
; Texto "TICKS: 000000"
; -------------------------------------------------------------
print_tick:
    mov edi,0xB8000
    mov esi,tick_text
    mov ecx,6
.lp:
    lodsb
    mov ah,0x0F
    stosw
    loop .lp

    mov eax,[ticks]
    mov ecx,10
    mov edi,0xB8000 + 12
.num_loop:
    xor edx,edx
    div ecx
    add dl,'0'
    mov dh,0x0F
    mov word [edi],dx
    add edi,2
    cmp eax,0
    jne .num_loop
    ret

tick_text db "TICKS:",0


; =============================================================
;                   Função de print no modo PM
; =============================================================
print_string_pm:
    ; esi = string
    ; edi = destino
    mov eax,0x0F20
.lp:
    lodsb
    cmp al,0
    je .done
    mov ah,0x0F
    mov [edi],ax
    add edi,2
    jmp .lp
.done:
    ret


; =============================================================
;                 Ponto principal do Kernel
; =============================================================
kernel_main:
    mov esi,kernel_msg
    mov edi,0xB8000 + 160
    call print_string_pm

.hang:
    jmp .hang

kernel_msg db "VentureOS Kernel Iniciado!",0


; =============================================================
;                    Bootloader padding
; =============================================================
times 510-($-$$) db 0
dw 0xAA55
