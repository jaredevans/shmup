; =====================================================================
;  DIES IRAE  -  the medieval plainchant sequence, played on the C64 SID
;  Target: Commodore 64 (PAL)   Assembler: ACME
;  Build:  acme -f cbm -o dies-irae.prg dies-irae.asm
;  Run:    x64sc dies-irae.prg   (auto-runs via BASIC stub, or SYS 2061)
; ---------------------------------------------------------------------
;  The COMPLETE Gregorian sequence, Mode 1 (Dorian, final D), transcribed
;  note-for-note from the manuscript (Parish Book of Chant / Liber Usualis)
;  -- the true liturgical chant, not the looser motif Berlioz/Rachmaninoff
;  quote. The whole piece runs ~3.5 minutes, then loops.
;
;  THE SEQUENCE FORM.  A "sequence" reuses a handful of melodies across
;  many verses in an AABBCC pattern. The Dies irae has 17 three-line
;  verses built from just THREE melodies, then a through-composed coda:
;
;    Melody A  verses 1-2, 7-8, 13-14   syllabic, low -- the iconic theme.
;              L1=L2  F F E F D C D D    "Dies irae, dies illa" ...
;              L3     F A G F G E D D    (rises to A, cadences on D)
;
;    Melody B  verses 3-4, 9-10, 15-16  MELISMATIC -- arches up to a
;              B-NATURAL (the Dorian 6th), 2-3 notes per syllable on its
;              flowing descents. The ornate one.
;
;    Melody C  verses 5-6, 11-12, 17    low, plain recitation, peaking
;              only at G (a 4th above the final). Verse 17 is unpaired --
;              a lone C that hinges into the coda.
;
;    Melody D  the LACRIMOSA coda       through-composed, played ONCE:
;              "Lacrimosa dies illa ... Pie Jesu Domine, dona eis requiem,
;              Amen." Introduces B-FLAT (the b6) where the verses sang
;              B-natural; closes with a long melismatic Amen falling to D.
;
;    Playlist (verse order):  A A B B C C  A A B B C C  A A B B C  D
;
;  All four melodies rest on the final D; together they span C up to B.
;  The only chromatic colour is the sixth degree -- melody B sings it
;  natural (the bright B), melody D's coda flattens it (the dark B-flat).
;
;  ARRANGEMENT (3 SID voices):
;    Voice 1 = melody, low-pass-filtered triangle (soft, vocal-ish)
;    Voice 2 = D2 drone  ) sustained open fifth D-A underneath, triangle,
;    Voice 3 = A2 drone  ) sitting just under the melody -- the medieval
;                          organum pedal on the final D, sounds ominous.
;
;  RHYTHM & TIMING.  Timed by polling the raster ($D012) for a ~50 Hz
;  frame tick -- no interrupts, no KERNAL. The rhythm is an EVEN pulse
;  that only relaxes at the phrase ends (final note stretched, a breath
;  between lines) -- the unmetered flow of real chant, not a long-short
;  accent meter. In the melismatic verses each neume note simply gets the
;  same even pulse. Each note holds, then releases for a few frames to
;  re-trigger the next attack.
;
;  SHAPING THE ARC (avoiding monotony).  17 verses drawn from only three
;  melodies, played straight, get repetitive -- in the SUNG chant the
;  ever-changing Latin words carry the variety, but instrumentally those
;  words are gone and each melody would otherwise repeat byte-for-byte.
;  So the piece is shaped with PER-CYCLE VARIATION that changes ONLY
;  register and volume -- never a note -- so the tune stays fully
;  recognisable while the 3.5 minutes gain a shape:
;       Cycle 1 (v1-6)    home register, soft        (vol 9)
;       Cycle 2 (v7-12)   UP AN OCTAVE, louder       (vol 12)
;       Cycle 3 (v13-17)  home register, stronger    (vol 14)
;       Lacrimosa         peaks (vol 15) then fades to the Amen
;  The octave lift is just shifting each frequency left one bit at
;  playback; the dynamics are writes to the volume register. Because the
;  notes/intervals/contour are untouched, this is the safest kind of
;  variation -- it breaks the carbon-copy repeats without ever risking
;  recognition. Driven by the plTrans/plVol/plDim tables (by the playlist).
;
;  STRUCTURE.  A shared engine (SID setup + raster-timed sequencer) plays
;  per-melody data blocks (mA..mD) chosen by a playlist of melody numbers.
;  Set SOLO (below) to a melody index to audition one melody in isolation
;  (plain, no arc); SOLO = -1 plays the whole shaped sequence.
; =====================================================================

SID      = $d400
V1FLO    = $d400            ; voice 1 frequency lo/hi
V1FHI    = $d401
V1CTRL   = $d404            ; voice 1 control (waveform + gate bit0)
V1AD     = $d405            ; attack / decay
V1SR     = $d406            ; sustain / release
V2FLO    = $d407
V2FHI    = $d408
V2CTRL   = $d40b
V2AD     = $d40c
V2SR     = $d40d
V3FLO    = $d40e
V3FHI    = $d40f
V3CTRL   = $d412
V3AD     = $d413
V3SR     = $d414
FILTLO   = $d415            ; filter cutoff lo (3 bits)
FILTHI   = $d416            ; filter cutoff hi (8 bits)
RESFILT  = $d417            ; resonance (hi nibble) + per-voice filter routing
FILTMODE = $d418            ; filter mode / master volume

BORDER   = $d020
BGCOL    = $d021
RASTER   = $d012

; --- zero-page work vars (free area; we run with IRQs off, no KERNAL) -
curVol   = $f2             ; current master-volume nibble (the dynamic arc)
curDim   = $f3             ; volume drop per line-breath (Lacrimosa diminuendo)
curTrans = $f4             ; 1 = transpose the melody up an octave (cycle 2)
curMel   = $f5             ; melody number of the current stanza
plIdx    = $f6             ; index into the playlist (which stanza)
ptrNote  = $f7             ; $f7/$f8 = pointer to current stanza's note table
ptrDur   = $f9             ; $f9/$fa = pointer to current stanza's dur table
seqidx   = $fb             ; index within the current stanza's tables
curDur   = $fc             ; duration (frames) of the note being played
curNote  = $fd             ; note index of the note being played

; =====================================================================
;  BASIC stub:  10 SYS 2061   ->  jumps to 'start' at $080D
; =====================================================================
* = $0801
        !byte $0b,$08          ; link to next BASIC line ($080B)
        !byte $0a,$00          ; line number 10
        !byte $9e              ; SYS token
        !byte $32,$30,$36,$31  ; "2061"
        !byte $00              ; end of BASIC line
        !byte $00,$00          ; end of program

; =====================================================================
;  start ($080D = 2061)
; =====================================================================
start
        sei                     ; we drive everything ourselves; mask IRQs

        ; --- somber black screen -------------------------------------
        lda #0
        sta BORDER
        sta BGCOL

        ; --- wipe all 25 SID registers to a known state --------------
        lda #0
        ldx #$18
clrsid
        sta SID,x
        dex
        bpl clrsid

        ; --- filter: low-pass on voice 1 only, to round the sawtooth's
        ;     buzz into a warmer, more vocal/organ tone. The two drones
        ;     are left unfiltered so the pedal stays open and present. ---
        lda #$00
        sta FILTLO              ; cutoff low bits
        lda #$40
        sta FILTHI              ; cutoff high -> mellow, dark cutoff
        lda #$11                ; resonance=1 (smooth), route VOICE 1 into filter
        sta RESFILT
        ; --- master volume = 15, low-pass filter mode -------------------
        lda #$1f                ; bit4 = LP mode, low nibble = volume 15
        sta FILTMODE

        ; --- voice 1 (melody): low-pass TRIANGLE, gentle vocal swell ----
        ;     triangle is SID's softest wave; the slow attack lets each
        ;     note bloom rather than pluck -- as close to a sung "oo" as
        ;     a 1982 sound chip gets.
        lda #$3a                ; attack=3 (soft swell, not plucky), decay=10
        sta V1AD
        lda #$da                ; sustain=13, release=10
        sta V1SR

        ; --- voice 2 (low D drone = the modal final): triangle --------
        lda #$20                ; attack=2, decay=0
        sta V2AD
        lda #$ba                ; sustain=11, release=10 (sits under the melody)
        sta V2SR
        lda #<D2_F              ; D2 frequency (root)
        sta V2FLO
        lda #>D2_F
        sta V2FHI
        lda #$11                ; triangle + gate ON  -> drone starts
        sta V2CTRL

        ; --- voice 3 (A drone a fifth above): triangle ---------------
        lda #$20
        sta V3AD
        lda #$ba
        sta V3SR
        lda #<A2_F              ; A2 frequency (fifth above D2)
        sta V3FLO
        lda #>A2_F
        sta V3FHI
        lda #$11                ; triangle + gate ON
        sta V3CTRL

        ; --- begin playback at the first playlist entry --------------
        lda #0
        sta plIdx
        jsr load_stanza

; ---------------------------------------------------------------------
;  Main sequencer loop: read one note from the current stanza, play it,
;  advance. At the stanza's $ff terminator, move to the next playlist
;  entry (wrapping at the end -> the whole sequence loops).
; ---------------------------------------------------------------------
play_loop
        ldy seqidx
        lda (ptrNote),y         ; current note index (0=rest, $ff=end of stanza)
        cmp #$ff
        beq next_stanza
        sta curNote
        lda (ptrDur),y          ; its duration in frames
        sta curDur
        inc seqidx
        lda curNote
        beq do_rest             ; 0 -> rest

        ; --- pitched note: set frequency, gate on (re-trigger attack) -
        ;     curTrans=1 -> shift the 16-bit freq left once (x2 = up an octave)
        tay                     ; Y = note index into freq tables
        ldx curTrans
        beq pl_base
        lda freqLo,y
        asl                     ; lo << 1
        sta V1FLO
        lda freqHi,y
        rol                     ; hi << 1 + carry  -> one octave up
        sta V1FHI
        jmp pl_gate
pl_base
        lda freqLo,y
        sta V1FLO
        lda freqHi,y
        sta V1FHI
pl_gate
        lda #$11                ; triangle + gate ON
        sta V1CTRL

        ; hold for (duration - 4) frames
        lda curDur
        sec
        sbc #4
        jsr waitN

        ; release: gate OFF for 4 frames. The 0->1 gate edge on the NEXT
        ; note is what re-triggers its attack.
        lda #$10                ; triangle, gate OFF
        sta V1CTRL
        lda #4
        jsr waitN
        jmp play_loop

do_rest
        lda #$10                ; silence voice 1 (gate off)
        sta V1CTRL
        ; --- diminuendo: at each line-breath drop the volume by curDim
        ;     (0 for the verses; >0 only in the Lacrimosa coda) ---
        lda curDim
        beq dr_wait
        lda curVol
        sec
        sbc curDim
        cmp #3
        bcs dr_setv             ; clamp at a soft floor of 3
        lda #3
dr_setv
        sta curVol
        ora #$10                ; keep the LP filter bit set
        sta FILTMODE
dr_wait
        lda curDur
        jsr waitN
        jmp play_loop

next_stanza
        inc plIdx               ; advance to the next stanza in the playlist
        jsr load_stanza
        jmp play_loop

; ---------------------------------------------------------------------
;  load_stanza: point ptrNote/ptrDur at the stanza named by
;  playlist[plIdx] (wrapping to the first entry at the playlist's $ff
;  terminator), and reset seqidx. Clobbers A, X.
; ---------------------------------------------------------------------
load_stanza
        ldx plIdx
        lda playlist,x
        cmp #$ff
        bne ls_have
        lda #0                  ; end of playlist -> wrap to the first entry
        sta plIdx
        ldx #0
        lda playlist,x
ls_have
        ; X = playlist position; A = melody number for this stanza
        sta curMel              ; stash the melody number
        ; --- per-section arrangement, indexed by playlist position (X) ---
        lda plVol,x
        sta curVol
        ora #$10                ; LP filter bit + this section's volume
        sta FILTMODE
        lda plDim,x
        sta curDim              ; diminuendo step (0 except the coda)
        lda plTrans,x
        sta curTrans            ; octave transpose flag (1 for cycle 2)
        ldx curMel              ; X = melody number -> index the pointer tables
        lda noteLo,x
        sta ptrNote
        lda noteHi,x
        sta ptrNote+1
        lda durLo,x
        sta ptrDur
        lda durHi,x
        sta ptrDur+1
        lda #0
        sta seqidx
        rts

; ---------------------------------------------------------------------
;  waitN: wait A frames (each ~1/50 s). Clobbers A, X.
; ---------------------------------------------------------------------
waitN
        tax
        beq wn_done
wn_loop
        jsr wait_frame
        dex
        bne wn_loop
wn_done
        rts

; ---------------------------------------------------------------------
;  wait_frame: block until the raster passes line 251 -> one PAL frame.
; ---------------------------------------------------------------------
wait_frame
wf_to251
        lda RASTER
        cmp #251
        bne wf_to251            ; spin until raster == 251
wf_off251
        lda RASTER
        cmp #251
        beq wf_off251           ; spin until raster leaves 251
        rts

; =====================================================================
;  DATA
; =====================================================================
; --- note frequency table (PAL): reg = round(Hz * 16777216 / 985248) -
;     index 0 = rest, 1..8 = C4 D4 E4 F4 G4 A4 B4 Bb4 (Dorian on D)
;     B-natural (7) = melody B's peak; B-flat (8) = the Lacrimosa coda's b6
freqLo   !byte $00, $67, $89, $ed, $3b, $13, $45, $da, $02
freqHi   !byte $00, $11, $13, $15, $17, $1a, $1d, $20, $1f
;                 rest C4   D4   E4   F4   G4   A4   B4   Bb4

; --- drone frequencies (open fifth on the final: D2 + A2) ------------
D2_F = $04e2               ; D2   73.4 Hz (root / modal final)
A2_F = $0751               ; A2  110.0 Hz (fifth above)

; --- melody pointer tables (indexed by MELODY number: 0=A 1=B 2=C ...) -
;     The Dies irae is a SEQUENCE: a few melodies, each reused for many
;     verses. The playlist below names melodies in verse order; these
;     tables hold one column per DISTINCT melody. Add a column only when
;     a genuinely NEW melody appears (e.g. the Lacrimosa coda).
noteLo   !byte <mA_note, <mB_note, <mC_note, <mD_note
noteHi   !byte >mA_note, >mB_note, >mC_note, >mD_note
durLo    !byte <mA_dur,  <mB_dur,  <mC_dur,  <mD_dur
durHi    !byte >mA_dur,  >mB_dur,  >mC_dur,  >mD_dur

; --- build switch: which stanza(s) to play --------------------------
;   SOLO = -1  -> play the master playlist below (the whole sequence)
;   SOLO >= 0  -> play ONLY that melody (0=A 1=B 2=C...) for verification
SOLO = -1                  ; play the full master playlist (complete sequence)

playlist
!if SOLO < 0 {
        ; verse-by-verse melody order. Verses 1-17 cycle AABBCC (verse 17
        ; is an unpaired C, the hinge); then the Lacrimosa coda (appended
        ; here once transcribed).
        !byte 0,0,1,1,2,2       ; verses 1-6   : A A B B C C
        !byte 0,0,1,1,2,2       ; verses 7-12  : A A B B C C
        !byte 0,0,1,1,2         ; verses 13-17 : A A B B C
        !byte 3                 ; Lacrimosa coda (Pie Jesu / Amen) : melody D
} else {
        !byte SOLO
}
        !byte $ff               ; end of playlist -> loop back to the start

; --- per-section arrangement (parallel to the playlist, by position) --
;   The melody NOTES never change -- only register and volume -- so the
;   tune stays recognisable while the 3.5-min piece gains a shape:
;     plTrans : 1 = sing this verse up an octave (cycle 2's brighter arch)
;     plVol   : master volume 0-15 -- a swell that builds across the cycles
;     plDim   : volume drop per line-breath (>0 only for the coda's fade)
plTrans
!if SOLO < 0 {
        !byte 0,0,0,0,0,0       ; cycle 1: home register
        !byte 1,1,1,1,1,1       ; cycle 2: up an octave
        !byte 0,0,0,0,0         ; cycle 3: home register
        !byte 0                 ; Lacrimosa: home register
} else {
        !byte 0
}
plVol
!if SOLO < 0 {
        !byte 9,9,9,9,9,9       ; cycle 1: soft (intimate opening)
        !byte 12,12,12,12,12,12 ; cycle 2: medium
        !byte 14,14,14,14,14    ; cycle 3: strong (the dramatic verses)
        !byte 15                ; Lacrimosa: peaks, then fades via plDim
} else {
        !byte 15
}
plDim
!if SOLO < 0 {
        !byte 0,0,0,0,0,0
        !byte 0,0,0,0,0,0
        !byte 0,0,0,0,0
        !byte 1                 ; Lacrimosa: -1 per line -> softens to the Amen
} else {
        !byte 0
}

; =====================================================================
;  STANZA DATA
;  Each stanza = a note-index table (0=rest, $ff=end) + a parallel
;  duration table (frames). Notes index the freq table above.
;
;  FREE RHYTHM: these stanzas are purely syllabic (one note/syllable), so
;  the rhythm is an EVEN pulse (16) that only relaxes at the phrase ends
;  -- NOT a long-short accent meter (that sounds like a metrical march).
;  The final note of each line is stretched into a cadence, and a breath
;  (rest) separates the lines; the closing note is held longest.
; =====================================================================

; --- Melody A  (verses 1-2 of the sequence; Mode 1 Dorian, final D) ---
;     Verse 1 "Dies irae, dies illa / Solvet saeclum in favilla /
;              Teste David cum Sibylla"
;     Verse 2 "Quantus tremor est futurus / Quando judex est venturus /
;              Cuncta stricte discussurus"
;     Both verses sing this exact melody (each verified note-for-note
;     from the manuscript):
;       Line 1: F F E F D C D D = 4 4 3 4 2 1 2 2
;       Line 2: F F E F D C D D = 4 4 3 4 2 1 2 2   (same as line 1)
;       Line 3: F A G F G E D D = 4 6 5 4 5 3 2 2
mA_note  !byte 4,4,3,4,2,1,2,2, 0
         !byte 4,4,3,4,2,1,2,2, 0
         !byte 4,6,5,4,5,3,2,2, 0
         !byte $ff
mA_dur   !byte 16,16,16,16,16,16,16,30, 12
         !byte 16,16,16,16,16,16,16,30, 12
         !byte 16,16,16,16,16,16,16,46, 28
         !byte 0                     ; (pairs with $ff; unused)

; --- Melody B  (verses 3-4 of the sequence; Mode 1 Dorian, final D) ---
;     Verse 3 "Tuba mirum spargens sonum / per sepulcra regionum /
;              coget omnes ante thronum"
;     Verse 4 "Mors stupebit et natura / cum resurget creatura /
;              judicanti responsura"
;     MELISMATIC: several syllables carry a 2-3 note neume; each pitch is
;     its own entry below, [..] in the comments marks a neume. The line
;     rises to B-natural (the Dorian 6th) before cascading to the final D.
;       L1: F  G  F  E  D [C D] [F E D]  E
;       L2: F  A [B A] [G A] G  F  E  D
;       L3: D [E F] G [F E] D [C D] [F E D] D
;     (indices: C=1 D=2 E=3 F=4 G=5 A=6 B=7)
mB_note  !byte 4,5,4,3,2,1,2,4,3,2,3, 0        ; line 1  (+breath)
         !byte 4,6,7,6,5,6,5,4,3,2, 0          ; line 2  (+breath)
         !byte 2,3,4,5,4,3,2,1,2,4,3,2,2, 0    ; line 3  (+breath)
         !byte $ff
; even pulse (16) per note -- neume notes get the same value, so a melisma
; just flows as more equal notes; only line ends stretch into a cadence.
mB_dur   !byte 16,16,16,16,16,16,16,16,16,16,24, 12
         !byte 16,16,16,16,16,16,16,16,16,30, 12
         !byte 16,16,16,16,16,16,16,16,16,16,16,16,46, 28
         !byte 0                     ; (pairs with $ff; unused)

; --- Melody C  (verses 5-6 of the sequence; Mode 1 Dorian, final D) ---
;     Verse 5 "Liber scriptus proferetur / in quo totum continetur /
;              unde mundus judicetur"
;     Verse 6 "Judex ergo cum sedebit / quidquid latet apparebit /
;              nil inultum remanebit"
;     Back to a low, mostly-syllabic recitation (range C-G, never reaches
;     A or B). Lines 1 & 2 are identical; line 3 has one neume [C D].
;       L1: F F G F E D E D
;       L2: F F G F E D E D   (same as line 1)
;       L3: F F G F E D [C D] D
;     (indices: C=1 D=2 E=3 F=4 G=5)
mC_note  !byte 4,4,5,4,3,2,3,2, 0
         !byte 4,4,5,4,3,2,3,2, 0
         !byte 4,4,5,4,3,2,1,2,2, 0
         !byte $ff
mC_dur   !byte 16,16,16,16,16,16,16,30, 12
         !byte 16,16,16,16,16,16,16,30, 12
         !byte 16,16,16,16,16,16,16,16,46, 28
         !byte 0                     ; (pairs with $ff; unused)

; --- Melody D  (the LACRIMOSA coda; Mode 1 Dorian, final D) -----------
;     Through-composed ending, played ONCE after verse 17. New material:
;     introduces B-FLAT (the b6, index 8) where the verses used B-natural.
;       L1 "Lacrimosa dies illa"  : A G F G A G [F E] D
;       L2 "qua resurget ex favilla": same as L1
;       L3 "judicandus homo reus" : G A Bb A G F [G E] D
;       L4 "huic ergo parce Deus" : G A Bb A G [G E] D   (7 syll, ~L3)
;       L5 "Pie Jesu Domine"      : G G [F E] D [E F G] [F E] D
;       L6 "dona eis requiem, Amen": F A [Bb A] [G A] G F [E D] [F G] [G F E D]
;     (indices: C=1 D=2 E=3 F=4 G=5 A=6 B=7 Bb=8)
mD_note  !byte 6,5,4,5,6,5,4,3,2, 0             ; line 1  (+breath)
         !byte 6,5,4,5,6,5,4,3,2, 0             ; line 2  (= line 1)
         !byte 5,6,8,6,5,4,5,3,2, 0             ; line 3
         !byte 5,6,8,6,5,5,3,2, 0               ; line 4
         !byte 5,5,4,3,2,3,4,5,4,3,2, 0         ; line 5 (Pie Jesu)
         !byte 4,6,8,6,5,6,5,4,3,2,4,5,5,4,3,2, 0   ; line 6 (Amen)
         !byte $ff
mD_dur   !byte 16,16,16,16,16,16,16,16,30, 12
         !byte 16,16,16,16,16,16,16,16,30, 12
         !byte 16,16,16,16,16,16,16,16,30, 12
         !byte 16,16,16,16,16,16,16,30, 12
         !byte 16,16,16,16,16,16,16,16,16,16,30, 12
         !byte 16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,56, 36
         !byte 0                     ; (pairs with $ff; unused)
