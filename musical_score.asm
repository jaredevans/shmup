;  DIES IRAE -- battle remix for a shoot-'em-up (auto-generated data).
; =====================================================================
;  MUSICAL_SCORE  -  a fast, "battle" arrangement of DIES IRAE for the
;  SID, intended as background music for a horizontal shoot-'em-up.
;  Target: C64 (PAL)   Assembler: ACME
;  Build:  acme -f cbm -o musical_score.prg musical_score.asm
;  Run:    x64sc musical_score.prg   (auto-runs, or SYS 2061)
; ---------------------------------------------------------------------
;  The solemn chant is re-cast as driving game music in D minor:
;    Voice 1 = LEAD   : pulse wave -- the Dies Irae theme, energised, in
;                       sections (intro -> theme -> octave-up variation ->
;                       climax with a fast descending run), so it does not
;                       just loop one phrase.
;    Voice 2 = BASS   : pulse wave -- driving 8th notes on a descending
;                       D-C-Bb-A bassline (galloping octaves in the climax).
;    Voice 3 = DRUMS  : noise/triangle -- kick + snare backbeat + hi-hats,
;                       with snare fills.
;  A simple frame-tick player advances all three voices on the ~50 Hz
;  raster beat. The whole pattern is ~25 s and loops.
; =====================================================================

V1FLO=$d400
V1CTRL=$d404
V1AD=$d405
V1SR=$d406
V2FLO=$d407
V2CTRL=$d40b
V2AD=$d40c
V2SR=$d40d
V3FLO=$d40e
V3CTRL=$d412
V3AD=$d413
V3SR=$d414
VOL=$d418
RASTER=$d012

lead_ptr=$f0    ; $f0/$f1
lead_cd =$f2
bass_ptr=$f3    ; $f3/$f4
bass_cd =$f5
drum_ptr=$f6    ; $f6/$f7
drum_cd =$f8
tmparg  =$f9

* = $0801
        !byte $0b,$08,$0a,$00,$9e,$32,$30,$36,$31,$00,$00,$00   ; 10 SYS 2061

start
        sei
        lda #0
        sta $d020
        sta $d021
        ldx #$18                ; clear SID
clr     sta $d400,x
        dex
        bpl clr
        lda #$0f                ; master volume, no filter
        sta VOL
        ; voice 1 (lead) pulse 50%, punchy-singing envelope
        lda #$00 : sta $d402
        lda #$08 : sta $d403
        lda #$1a : sta V1AD     ; atk1 dec10
        lda #$a8 : sta V1SR     ; sus10 rel8
        ; voice 2 (bass) pulse, plucky
        lda #$00 : sta $d409
        lda #$08 : sta $d40a
        lda #$0a : sta V2AD     ; atk0 dec10
        lda #$06 : sta V2SR     ; sus0 rel6
        ; init the three voice pointers + countdowns (0 -> load on first tick)
        lda #<lead_data : sta lead_ptr
        lda #>lead_data : sta lead_ptr+1
        lda #<bass_data : sta bass_ptr
        lda #>bass_data : sta bass_ptr+1
        lda #<drum_data : sta drum_ptr
        lda #>drum_data : sta drum_ptr+1
        lda #0 : sta lead_cd : sta bass_cd : sta drum_cd

main
        jsr wait_frame
        jsr tick_lead
        jsr tick_bass
        jsr tick_drums
        jmp main

wait_frame
wf1     lda RASTER
        cmp #251
        bne wf1
wf2     lda RASTER
        cmp #251
        beq wf2
        rts

; ---- LEAD (voice 1, pulse) -----------------------------------------
tick_lead
        lda lead_cd
        bne tl_dec
        ldy #0
        lda (lead_ptr),y
        cmp #$ff
        bne tl_g
        lda #<lead_data : sta lead_ptr
        lda #>lead_data : sta lead_ptr+1
        ldy #0
        lda (lead_ptr),y
tl_g    sta tmparg
        iny
        lda (lead_ptr),y
        sta lead_cd
        lda lead_ptr : clc : adc #2 : sta lead_ptr
        bcc tl_t : inc lead_ptr+1
tl_t    lda tmparg
        bne tl_on
        lda #$40 : sta V1CTRL           ; rest -> gate off
        jmp tl_dec
tl_on   tax
        lda freqLo,x : sta V1FLO
        lda freqHi,x : sta V1FLO+1
        lda #$40 : sta V1CTRL           ; pulse, gate off (retrigger)
        lda #$41 : sta V1CTRL           ; pulse, gate on
tl_dec  dec lead_cd
        rts

; ---- BASS (voice 2, pulse) -----------------------------------------
tick_bass
        lda bass_cd
        bne tb_dec
        ldy #0
        lda (bass_ptr),y
        cmp #$ff
        bne tb_g
        lda #<bass_data : sta bass_ptr
        lda #>bass_data : sta bass_ptr+1
        ldy #0
        lda (bass_ptr),y
tb_g    sta tmparg
        iny
        lda (bass_ptr),y
        sta bass_cd
        lda bass_ptr : clc : adc #2 : sta bass_ptr
        bcc tb_t : inc bass_ptr+1
tb_t    lda tmparg
        bne tb_on
        lda #$40 : sta V2CTRL
        jmp tb_dec
tb_on   tax
        lda freqLo,x : sta V2FLO
        lda freqHi,x : sta V2FLO+1
        lda #$40 : sta V2CTRL
        lda #$41 : sta V2CTRL
tb_dec  dec bass_cd
        rts

; ---- DRUMS (voice 3, noise/triangle) -------------------------------
tick_drums
        lda drum_cd
        beq td_load
        dec drum_cd
        rts
td_load ldy #0
        lda (drum_ptr),y
        cmp #$ff
        bne td_g
        lda #<drum_data : sta drum_ptr
        lda #>drum_data : sta drum_ptr+1
        ldy #0
        lda (drum_ptr),y
td_g    sta tmparg
        iny
        lda (drum_ptr),y
        sta drum_cd
        lda drum_ptr : clc : adc #2 : sta drum_ptr
        bcc td_t : inc drum_ptr+1
td_t    lda tmparg
        bne td_hit                      ; nonzero -> a drum hit
        jmp td_dec                      ; 0 -> rest (let prev decay)
td_hit  cmp #1
        bne td_sn
        ; kick: low triangle, fast decay
        lda #$06 : sta V3AD
        lda #$00 : sta V3SR
        lda #$80 : sta V3FLO
        lda #$04 : sta V3FLO+1
        lda #$10 : sta V3CTRL
        lda #$11 : sta V3CTRL
        jmp td_dec
td_sn   cmp #2
        bne td_hat
        ; snare: mid noise
        lda #$06 : sta V3AD
        lda #$00 : sta V3SR
        lda #$00 : sta V3FLO
        lda #$20 : sta V3FLO+1
        lda #$80 : sta V3CTRL
        lda #$81 : sta V3CTRL
        jmp td_dec
td_hat  ; hi-hat: high noise, very fast decay
        lda #$02 : sta V3AD
        lda #$00 : sta V3SR
        lda #$00 : sta V3FLO
        lda #$70 : sta V3FLO+1
        lda #$80 : sta V3CTRL
        lda #$81 : sta V3CTRL
td_dec  dec drum_cd
        rts

; =====================================================================
;  DATA
; =====================================================================
freqLo
         !byte 0,90,156,226,45,123,207,39,133,232,81,193,55,180,56,196,89,247,157,78,10,208,162,129,109,103,112,137,178,237,59,156,19,160,69,2,218,206,224,17,100,218,118,57,38,64,137,4,180,156
freqHi
         !byte 0,4,4,4,5,5,5,6,6,6,7,7,8,8,9,9,10,10,11,12,13,13,14,15,16,17,18,19,20,21,23,24,26,27,29,31,32,34,36,39,41,43,46,49,52,55,58,62,65,69

; --- streams: pairs of (value, duration-in-frames); $ff = loop ---
lead_data
         !byte 0,80,0,80,0,80,0,40,34,10,35,10,37,10,39,10
         !byte 30,10,30,10,29,10,30,10,27,10,25,10,27,10,27,10
         !byte 30,10,34,10,32,10,30,10,32,10,29,10,27,10,27,10
         !byte 30,10,30,10,29,10,30,10,27,10,25,10,27,10,27,10
         !byte 30,10,34,10,32,10,30,10,32,10,29,10,27,10,27,10
         !byte 42,10,42,10,41,10,42,10,39,10,37,10,39,10,39,10
         !byte 42,10,46,10,44,10,42,10,44,10,41,10,39,10,39,10
         !byte 42,10,42,10,41,10,42,10,39,10,37,10,39,10,39,10
         !byte 42,10,46,10,44,10,42,10,44,10,41,10,39,10,39,10
         !byte 30,10,30,10,29,10,30,10,27,10,25,10,27,10,27,10
         !byte 30,10,34,10,32,10,30,10,32,10,29,10,27,10,27,10
         !byte 30,10,30,10,29,10,30,10,27,10,25,10,27,10,27,10
         !byte 39,5,37,5,35,5,34,5,32,5,30,5,29,5,27,5
         !byte 27,40,255
bass_data
         !byte 15,10,15,10,15,10,15,10,15,10,15,10,15,10,15,10
         !byte 13,10,13,10,13,10,13,10,13,10,13,10,13,10,13,10
         !byte 11,10,11,10,11,10,11,10,11,10,11,10,11,10,11,10
         !byte 10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10
         !byte 15,10,15,10,15,10,15,10,15,10,15,10,15,10,15,10
         !byte 13,10,13,10,13,10,13,10,13,10,13,10,13,10,13,10
         !byte 11,10,11,10,11,10,11,10,11,10,11,10,11,10,11,10
         !byte 10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10
         !byte 15,10,15,10,15,10,15,10,15,10,15,10,15,10,15,10
         !byte 13,10,13,10,13,10,13,10,13,10,13,10,13,10,13,10
         !byte 11,10,11,10,11,10,11,10,11,10,11,10,11,10,11,10
         !byte 10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10
         !byte 15,10,15,10,27,10,15,10,15,10,27,10,15,10,15,10
         !byte 13,10,13,10,25,10,13,10,13,10,25,10,13,10,13,10
         !byte 11,10,11,10,23,10,11,10,11,10,23,10,11,10,11,10
         !byte 10,10,10,10,22,10,10,10,10,10,22,10,10,10,10,10
         !byte 255
drum_data
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,0,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,3,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,0,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,3,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,0,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,3,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,0,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,3,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,0,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,3,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,0,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,3,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,0,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,3,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,0,5
         !byte 1,5,0,5,3,5,0,5,2,5,2,5,2,5,2,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,0,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,3,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,0,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,3,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,0,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,3,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,0,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,3,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,0,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,3,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,0,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,3,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,0,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,3,5
         !byte 1,5,0,5,3,5,0,5,2,5,0,5,1,5,0,5
         !byte 1,5,0,5,3,5,0,5,2,5,2,5,2,5,2,5
         !byte 255
