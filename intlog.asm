; Push all parameters onto stack
%macro mpush 1-*
    %rep %0
        push %1
        %rotate 1
    %endrep
%endmacro

org 0x100

section .text

start:
    call parse_args
    call install_ints

    ; TSR
    mov dx, 100h;32h
    mov al, 0h
    mov ah, 31h
    int 21h

; Parse arguments (minimal syntax checking)
; Input: none
; Output: none
; Clobber: ax, bx
parse_args:
    cmp [ds:80h], byte 18  ; At least " 2x 4x 4x 2x 1c"
    jl .parse_args_usage
    cmp [ds:84h], byte 20h ; Space "2x 4x"
    jne .parse_args_usage
    cmp [ds:89h], byte 20h ; Space "4x 4x"
    jne .parse_args_usage
    cmp [ds:8eh], byte 20h ; Space "4x 2x"
    jne .parse_args_usage
    cmp [ds:91h], byte 20h ; Space "2x 1c"
    jne .parse_args_usage
    cmp [ds:92h], byte 20h ; Filename must not start with space
    jle .parse_args_usage

    ; Set end of string to null
    movzx bx, byte[ds:80h]
    mov [bx+81h], byte 0
    
    ; Save interrupt
    mov bx, 82h
    mov cx, 2
    call parse_hex
    mov [cs:IntRepl], al

    ; Save dump info
    mov bx, 85h
    mov cx, 4
    call parse_hex
    mov [cs:DumpSeg], ax

    mov bx, 8ah
    mov cx, 4
    call parse_hex
    mov [cs:DumpOff], ax

    mov bx, 8fh
    mov cx, 2
    call parse_hex
    mov [cs:DumpSize], al

    ret

.parse_args_usage:
    ; Incorrect parameters given, show usage
    mov ax, 0900h
    mov dx, StrUsage
    int 21h

    ; Quit
    int 20h

; Save and replace requested interrupt vector
; Input: none
; Output: none
; Clobber: ax, bx, dx, ds, es
install_ints:
    ; Save DOS vector
    mov ah, 35h
    mov al, 21h
    int 21h
    mov [cs:DOSVector], bx
    mov [cs:DOSVector+2], es

    ; Save interrupt vector
    mov ah, 35h
    mov al, [cs:IntRepl]
    int 21h
    mov [cs:IntVector], bx
    mov [cs:IntVector+2], es

    ; Set new interrupt vector
    mov dx, receive_int
    mov ax, cs
    mov ds, ax

    mov ah, 25h
    mov al, [cs:IntRepl]
    int 21h

    ret

; Receive, log, and send interrupt
; Inputs: none
; Output: none
; Clobber: none
receive_int:
    pushf
    pusha
    push ds
    
    push ax
    push bx

    ; Save calling CS:IP (INTs are far calls)
    mov bx, sp
    mov ax, [bx + 18h]
    sub ax, 2
    mov [cs:CallCSIP], ax
    mov ax, [bx + 1Ah]
    mov [cs:CallCSIP + 02h], ax

    ; Save calling SP
    mov [cs:CallSP], sp
    add [cs:CallSP], word 2eh

    ; Save DS
    mov [cs:CallDS], ds

    pop bx
    pop ax

    ; Log request
    call log_entry

    pop ds
    popa
    popf

    ; Send to original interrupt
    jmp far [cs:IntVector]

; Log registers to a file
; Inputs: all registers
; Output: none
; Clobber: ax, bx, cx, dx, 
log_entry:
    ; Save registers for log
    mpush dx, ss, es, ds, di, si, bp
    mpush word [cs:CallSP], dx, cx, bx, ax
    mpush word [cs:CallCSIP], word [cs:CallCSIP + 02h]

    ; Switch data segment from calling process to TSR process
    mov ax, cs
    mov ds, ax
    
    ; Open file for appending
    call open_append

    ; Write registers to disk
    mov si, 12

.log_entry_write:
    pop ax                 ; Get register value 
    mov bx, StrAddr+2
    call convert_hex4

    ; Write message and tab to disk
    mov cx, StrAddrLen
    mov dx, StrAddr
    call write_string

    mov cx, 1
    mov dx, StrTab
    call write_string

    dec si
    cmp si, 0
    jge .log_entry_write
    
    ; Write DX string
    pop dx
    call write_dxstr
   
    ; Write memory dump 
    call write_dump

    ; Close file
    mov ax, 3e00h
    mov bx, [cs:LogHandle]
    pushf
    call far [cs:DOSVector]

    ret

; Convert value to 4 hex digits
; Input: ax (word - value), bx (char * - destination)
; Output: none
; Clobber: ax, bx, dx, di
convert_hex4:
    mov di, 3              ; Write 0-3 digits

.convert_hex4_loop:
    mov dx, ax
    and dl, 0fh
    add dl, '0'
    cmp dl, '9'
    jle .convert_hex4_write
    add dl, 7              ; Adjust for A-F

.convert_hex4_write:
    mov [cs:bx+di], dl

    shr ax, 4
    dec di
    cmp di, 0
    jge .convert_hex4_loop

    ret

; Convert hex digits to value
; Input: bx (char * - string), cx (word - num digits)
; Output: ax (value)
; Clobber: ax, cx, dl, si
parse_hex:
    mov ax, 0
    mov si, 0

.parse_hex_loop:
    shl ax, 4
    movzx dx, byte [bx+si]
    sub dl, "0"
    cmp dl, 9
    jle .parse_hex_converted
    sub dl, 7

.parse_hex_converted:
    or ax, dx
    inc si
    cmp si, cx 
    jl .parse_hex_loop    

    ret

; Open/Create file and start append
; Input: none
; Output: none
; Clobber: ax, bx, cx, dx
open_append:
    ; Open file
    mov ax, 3d01h
    mov dx, LogFile
    pushf
    call far [cs:DOSVector]
    mov [cs:LogHandle], ax
    jnc .open_append_seek

    ; Create file
    mov ax, 3c00h
    mov cx, 0
    mov dx, LogFile
    pushf
    call far [cs:DOSVector]
    mov [cs:LogHandle], ax

    ; Write header
    mov cx, StrHeaderLen
    mov dx, StrHeader
    call write_string

.open_append_seek:
    ; Move to end
    mov ax, 4202h
    mov bx, [cs:LogHandle]
    mov cx, 0
    mov dx, 0
    pushf
    call far [cs:DOSVector]

    ret

; Write message to disk
; Input: cx (int - string length), dx (char * - string)
; Output: none
; Clobber: ax, bx, cx, dx
write_string:
    mov ax, 4000h
    mov bx, [cs:LogHandle]
    pushf
    call far [cs:DOSVector]
    
    ret

; Write valid ASCII string to disk
; Input: dx (char * - string)
; Output: none
; Clobber: ax, bx, cx, dx, si
write_dxstr:
    mov ds, [cs:CallDS]
    mov bx, dx
    mov si, 0

    ; Find last printable ASCII character (20h-7eh)    
.write_dxstr_loop:
    cmp [bx+si], byte 20h
    jl .write_dxstr_done
    cmp [bx+si], byte 7eh
    jg .write_dxstr_done
    inc si
    jmp .write_dxstr_loop

.write_dxstr_done:
    mov cx, si
    call write_string

    ; Reset DS to CS
    mov ax, cs
    mov ds, ax

    mov cx, 1
    mov dx, StrTab
    call write_string

    ret

; Write memory dump values to disk
; Input: none
; Output: none
; Clobber: ax, bx, cx, dx, si, di
write_dump:
    push es

    mov es, [cs:DumpSeg]
    mov bx, [cs:DumpOff]
    mov si, 0
    
.log_entry_loop:
    mov ax, [es:bx+si]
    push bx
    mov bx, StrAddr+2
    call convert_hex4

    ; Write message and tab to disk
    mov cx, StrAddrLen
    mov dx, StrAddr
    call write_string

    mov cx, 1
    mov dx, StrTab
    call write_string

    pop bx
    add si, 2
    movzx cx, [cs:DumpSize]
    cmp si, cx
    jl .log_entry_loop

    ; Write EOL
    mov cx, 2
    mov dx, StrEOL
    call write_string

    pop es

    ret

section .data

LogFile equ 92h

IntRepl db 0
DumpSeg dw 0
DumpOff dw 0
DumpSize db 0
IntVector dd 0
DOSVector dd 0
CallDS dw 0
CallCSIP dd 0
CallSP dw 0
LogHandle dw 0

StrTab db 09h
StrEOL db 0dh, 0ah
StrAddr db "0x0000"
StrAddrLen equ $-StrAddr
StrHeader db "CS", 09h, "IP", 09h, "AX", 09h, "BX", 09h, "CX", 09h, "DX", 09h, 
          db "SP", 09h, "BP", 09h, "SI", 09h, "DI", 09h, 
          db "DS", 09h, "ES", 09h, "SS", 09h, "DXStr", 09h, "Mem", 0dh, 0ah
StrHeaderLen equ $-StrHeader
StrInstalled db "IntLog installed!"
StrInstalledLen equ $-StrInstalled
StrUsage db "IntLog 1.0", 0dh, 0ah, 0dh, 0ah, "Syntax: INTLOG <int:2> <dump seg:4> <dump off:4> <dump size:2> <filename>", 0dh, 0ah, 
         db "(all values must be specified as capital hex digits of the count indicated)", 0dh, 0ah, "$"

