; PHOSPHOR 464: kommentierter Quelltext der vollstaendigen Demo
; Ziel: Schneider/Amstrad CPC 464, 64 KiB RAM, Z80A, RASM-Syntax.
; Startadresse #4000. Die Show endet mit einem stehenden Schlussbild.
; Ein Reset fuehrt zur Firmware zurueck; die Demo restauriert kein BASIC.
;
; LESEHILFE
; # bezeichnet Hexadezimalzahlen, alle anderen Zahlen sind dezimal.
; LD A,(wert) liest ein Byte aus RAM; LD A,wert laedt die Konstante.
; DW schreibt ein Wort als Lowbyte, Highbyte (Little Endian).
; OR A prueft A und loescht Carry; vor SBC HL,DE verhindert es einen
; unbeabsichtigten zusaetzlichen Abzug durch einen alten Carry-Zustand.
; CALL legt die Ruecksprungadresse auf dem Stack ab; RET holt sie zurueck.
; Die Effektroutinen duerfen Arbeitsregister veraendern. Jede Routine
; richtet ihre benoetigten Register neu ein. Nur beschriebene Helfer
; wie ay_write haben engere Vereinbarungen zur Registererhaltung.
;
; ABLAUF UND ZEITBASIS
; scene: 0 Logo, 1 See, 2 Strasse, 3 Landschaft, 4 Mode-Wechsel,
;        5 Schwarzweiss-Interferenz, 6 Finale.
; main_loop wartet auf VSYNC, zeichnet einen Teil des Effekts, spielt
; einen Musikschritt und aktualisiert Vorhang und Szenenzaehler.
; DI bleibt aktiv. Die Show fragt VSYNC direkt am PPI ab; sie benutzt
; weder den Firmware-Fast-Ticker noch einen eigenen Interrupt-Handler.
; Standardbild: 312 Rasterzeilen * 64 us = 19968 us, etwa 50,08 Hz.
; Ein NOP dauert im CPC 1 us. Die WAIT-Schaltung verlaengert viele
; andere Befehle; reine Z80-Taktzahlen / 4 reichen zur Planung nicht.
; Mode 2 baut ein Muster in 4 Frames auf, die Landschaft in 8 Frames.
; Der Musikplayer erhaelt trotzdem in jedem Videoframe einen Aufruf.
; Beim Szenenwechsel entpackt die CPU Daten ausserhalb dieses Takts.
;
; SPEICHERPLAN
; #0000..#3fff: je Szene Wasserquelle, Strassenphasen, Scrolltext oder
;              zweite Bildschirmseite fuer Landschaft / Mode 2.
; #4000..program_end-1: Code, Arbeitsvariablen, Tabellen, LZ48-Daten.
; #b800..#b83f: 16 Adresspaare fuer den POP-Lesestrom der Landschaft.
; #bff0: Anfang des normalen Stacks, der zu kleineren Adressen waechst.
; #c000..#ffff: erste Bildschirmseite; ROM-Overlays bleiben abgeschaltet.
; Code und Tabellen liegen bei dieser Fassung in 28813 Bytes bis #b08c.
;
; BILDSPEICHER UND FARBEN
; Zeilenoffset(y) = (y AND 7)*#800 + (y >> 3)*80.
; Beispiel: y=0 -> #0000, y=1 -> #0800, y=7 -> #3800, y=8 -> #0050.
; Dazu kommen Seitenbasis (#0000/#c000) und die Byte-Spalte (0..79).
; Mode 0: ein Byte enthaelt zwei 4-Bit-Farbnummern, verschachtelt:
; Bits 7,3,5,1 gehoeren zu Farbbit 0,1,2,3 des linken Pixels,
; Bits 6,2,4,0 entsprechend zum rechten Pixel.
; Mode 2: Bit 7 ist das linke von acht Pixeln, Bit 0 das rechte.
; Eine Farbnummer/Pen waehlt einen Paletteneintrag. Erst dessen
; Gate-Array-Farbcode bestimmt die RGB-Farbe. Codes #40..#5f sind
; Hardwarewerte; sie entsprechen nicht den BASIC-INK-Farbnummern.
;
; I/O: OUT (C),A legt das volle BC auf den Z80-Adressbus.
; #7fxx: Gate Array; #bcxx: CRTC-Registerwahl; #bdxx: CRTC-Daten.
; #f4xx: PPI Port A / AY-Daten; #f5xx: PPI Port B / VSYNC in Bit 0.
; #f6xx: PPI Port C / AY-Steuerleitungen; #f7xx: PPI-Steuerwort.
; Die verwendeten Bausteine ignorieren hier die unteren Adressbits.
; Deshalb kann OUT (C),C zugleich Port waehlen und C als Wert ausgeben.
;
; TABELLEN UND ENTWICKLUNGSWERKZEUGE
; tools/make_assets.py erzeugt Grafik, Muster, Zeilenadressen und Noten.
; tools/make_terrain.py erzeugt Hoehenkarte und Perspektivtabellen.
; RASM komprimiert INCL48-Dateien beim Build. Der eingebundene
; LZ48-Entpacker stammt von Edouard Berge aus tools/rasm/decrunch.
; Hardware-Erlaeuterungen: docs/PINBELEGUNGEN.md, docs/QUELLEN.md,
; docs/Z80A-UNDOKUMENTIERTE-OPCODES.md und docs/MODE-2-UND-INTERLACE.md.
; Emulatorpruefung: CRTC 0/1/2; Originalrechner noch nicht geprueft.
;
        org #4000
        run #4000
; EINSTIEG: Bus und Firmwarezustand unter eigene Kontrolle nehmen.
; DI sperrt maskierbare IRQs, damit die Firmware weder Palette noch
; Register waehrend unserer zeitkritischen Routinen veraendert.
; #8c = %10001100: Gate-Array-Modusregister, beide ROMs aus, Mode 0.
; RAM unter den ROMs wird damit auch beim LESEN sichtbar. Schreibzugriffe
; auf diese Adressen erreichen auf dem CPC ohnehin das darunterliegende RAM.
; #82 am PPI: Mode 0, Port A und C Ausgaenge, Port B Eingang.
; BFF0 bietet Platz fuer verschachtelte CALLs oberhalb der Arbeitstabellen.
start:
        di                        ; Firmware-IRQs ab hier sperren
        ld sp,#bff0               ; eigenen Stack oberhalb von Code und Tabellen aufsetzen
        ld bc,#7f8c               ; B waehlt Gate Array, C enthaelt das Moduswort #8c
        out (c),c                 ; #8c ausgeben: Mode 0, unteres und oberes ROM aus
        ld hl,crtc_defaults
        ld e,0
; R0 bis R13 der Reihe nach setzen. E zaehlt das Register, HL die Werte.
; Der Wechsel B=#bc -> #bd laesst C unveraendert: Registerwahl, dann Daten.
; R6 startet bei null; das Bild bleibt bis zum Oeffnen des Vorhangs schwarz.
crtc_init:
        ld b,#bc
        out (c),e                 ; CRTC: Register E auswaehlen
        inc b                     ; #bc -> #bd, zum Datenport wechseln
        ld a,(hl)
        out (c),a                 ; Tabellenwert in das ausgewaehlte Register schreiben
        inc hl
        inc e
        ld a,e
        cp 14                     ; Register 0 bis 13 sind nach 14 Werten fertig
        jr nz,crtc_init
        ld bc,#f782               ; PPI-Steuerport #f7xx und Konfiguration #82
        out (c),c                 ; A/C als Ausgabe, B als Eingabe konfigurieren
        xor a                     ; A=0 fuer die folgenden Zustandsbytes
        ld (scene),a
        ld (phase),a
        ld (beat_frame),a
        ld (song_step),a
        ld (finished),a
; Einsprung auch fuer die Debug-Szenentests: scene muss bereits stimmen.
; init_scene entpackt das Motiv und initialisiert die benoetigten Daten.
scene_entry:
        call init_scene
; PRO FRAME: Auf eine neue steigende VSYNC-Flanke warten.
; FRAME_SYNCED ist der Messpunkt der Tests. Der normale Stack steht hier
; wieder auf #bff0, weil wait_vsync bereits mit RET zurueckgekehrt ist.
main_loop:
        call wait_vsync
; Szene 5 laeuft durchgehend in Mode 2. Die anderen Szenen beginnen
; in Mode 0; die Split-Szene schaltet erst innerhalb von raster_effect um.
; Logo, Split und Finale teilen sich die Palette/Raster-Routine.
frame_synced:
        ld a,(scene)
        cp 5
        jr z,frame_moire
        ld bc,#7f8c
        out (c),c
        ld a,(scene)
        cp 1
        jr z,frame_water
        ld a,(scene)
        cp 2
        jr z,frame_road
        cp 3
        jr z,frame_terrain
        call raster_effect
        jr frame_tail
frame_terrain:
        call terrain_effect
        jr frame_tail
frame_road:
        call road_effect
        jr frame_tail
frame_water:
        call water_effect
        jr frame_tail
frame_moire:
        call moire_effect
; Gemeinsamer Nachlauf. Die Grafikarbeit muss samt Musik und Verwaltung
; vor dem naechsten passenden VSYNC abgeschlossen sein. Sonst wartet
; wait_vsync bis zur folgenden Flanke und die Show verliert einen Frame.
; See, Strasse und Landschaft besitzen eigene Paletten; Mode 2 nutzt nur
; zwei Pens. Deshalb erhalten nur Logo, Split und Finale das Bodenlicht.
frame_tail:
        call music_tick
        ld a,(scene)
        cp 5
        jr z,skip_floor
        cp 3
        jr z,skip_floor
        cp 1
        jr z,skip_floor
        cp 2
        call nz,floor_tick
; scene_frame ist ein 16-Bit-Zaehler je Szene; phase ein umlaufendes
; 8-Bit-Animationsmass fuer die Show. Musikzaehler laufen ueber Szenen hinweg.
; Der Vergleich zieht die Szenenlaenge ab: Carry bedeutet noch nicht fertig.
; Nach Szene 6 folgt show_complete, statt wieder bei Szene 0 anzufangen.
skip_floor:
        ld a,(scene)
        cp 6
        call z,scroll_tick
        ld a,(phase)
        inc a
        ld (phase),a
        ld hl,(scene_frame)
        inc hl
        ld (scene_frame),hl
        call shutter
        call ending_volume
        ld hl,(scene_frame)
        ld de,(scene_length)
        or a
        sbc hl,de
        jp c,main_loop
        ld a,(scene)
        inc a
        cp 7
        jr z,show_complete
        ld (scene),a
        call init_scene
        jp main_loop
; Alle drei AY-Lautstaerkeregister auf null setzen. ay_write erhaelt E,
; daher gilt E=0 fuer R8, R9 und R10. R6=25 zeigt wieder alle 200 Zeilen.
; finished=1 ist ein Statusbyte fuer Aufnahme und Tests, kein Hardwareflag.
show_complete:
        ; Der Schlussakkord klingt aus. Schlussbild bleibt stehen.
        ld a,8
        ld e,0
        call ay_write
        ld a,9
        call ay_write
        ld a,10
        call ay_write
        ld a,25
        ld e,6
        call crtc_write
        ld a,1
        ld (finished),a
; Das Schlussbild bleibt im RAM und die Video-Hardware liest es weiter.
; Die CPU wartet nur noch auf Bildwechsel; sie startet die Musik nicht neu.
end_hold:
        call wait_vsync
        jp end_hold

; VSYNC-POLLING. Veraendert A, Flags und B; C darf beliebig sein.
; PPI-Port B, Bit 0 liefert den CRTC-VSYNC. RRA schiebt dieses Bit in Carry.
; Zuerst ein eventuell laufendes VSYNC abwarten, dann auf das naechste
; VSYNC warten. Nur auf ein gesetztes Bit zu pruefen, lieferte waehrend
; desselben Synchronimpulses mehrere scheinbare Bildanfaenge.
; Die Abtastschleife erzeugt einige us Phasenstreuung. Die 64-us-Rasterfolge
; ist innerhalb des Bildes konstant, ihr Start ist nicht auf einen CPU-Takt
; zur Flanke festgelegt. HALT eignet sich hier bei gesperrten IRQs nicht.
wait_vsync:
        ld b,#f5                  ; PPI-Port B; C spielt bei der Portauswahl keine Rolle
wait_vsync_end:
        in a,(c)                  ; PPI-Eingaenge lesen
        rra                       ; VSYNC-Bit 0 nach Carry
        jr c,wait_vsync_end       ; solange der alte Syncimpuls noch aktiv ist
wait_vsync_start:
        in a,(c)                  ; erneut den aktuellen PPI-Zustand lesen
        rra                       ; das Eingangsbit nach Carry schieben
        jr nc,wait_vsync_start    ; warten, solange noch kein neues VSYNC anliegt
        ret

; A=Daten, E=CRTC-Register. Nur Standardregister, R8 bleibt null.
; CRTC-HELFER. Eingabe: E=Registernummer, A=Wert. Veraendert BC.
; A, DE und HL bleiben erhalten. INC B veraendert die Flags.
; Aufrufer duerfen also Flags nicht ueber diesen Helfer hinweg verwenden.
; R12/R13 adressieren CRTC-Zeichenwoerter, nicht direkt CPU-Bytes.
; Mit R13=0 waehlt R12=#30 die CPU-Seite #c000, R12=0 die Seite #0000.
; Der CRTC uebernimmt die Startadresse an seinem Bild-/Adressladepunkt.
crtc_write:
        ld bc,#bc00               ; Register-Auswahlport
        out (c),e                 ; Registernummer aus E
        inc b                     ; Datenport #bd00; veraendert Flags
        out (c),a                 ; neuer Registerinhalt aus A
        ret
; SZENENAUFBAU. Veraendert die Arbeitsregister; laeuft ausserhalb der
; zeitkritischen Bildschleife. R6=0 verdeckt das Entpacken des neuen Motivs.
; R13=0 stellt den Adressoffset zurueck, R12=#30 die Seite #c000.
; Jedes Bild entpackt auf genau 16 KiB. Fuer den Tabellenzugriff gilt
; Adresse = pictures + 2*scene, weil jeder Eintrag ein 16-Bit-Zeiger ist.
; EX DE,HL bringt den gelesenen Quellzeiger in den Eingabeparameter HL
; von LZ48_decrunch. DE=#c000 gibt dessen Ausgabeziel an.
init_scene:
        ld a,15
        ld (volume_limit),a
        xor a
        ld e,6                    ; R6: Anzahl sichtbarer Zeichenzeilen
        call crtc_write           ; A nach CRTC-Register E, BC wird veraendert
        xor a
        ld e,13                   ; R13: unterer Teil der Bildstartadresse
        call crtc_write           ; A nach CRTC-Register E, BC wird veraendert
        ld a,48                   ; #30 als oberer Teil fuer Bildseite #c000
        ld e,12                   ; R12: oberer Teil der Bildstartadresse
        call crtc_write           ; A nach CRTC-Register E, BC wird veraendert
        ld bc,#7f8c
        out (c),c
        ld a,(scene)
        add a,a                   ; scene*2 fuer die Tabelle aus Wortzeigern
        ld e,a
        ld d,0
        ld hl,pictures
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl                  ; gelesenen Bildzeiger in Entpacker-Parameter HL bringen
        ld de,#c000
        call LZ48_decrunch
        ld hl,initial_palette
        ld bc,#7f00
        ld e,0
; 16 Pens initialisieren: erst Pen-Nummer 0..15, dann Hardwarefarbcode.
; Pen-Wahl 16 adressiert anschliessend den Rand; #54 setzt ihn schwarz.
; Musikphase und globaler Effektzaehler bleiben beim Szenenwechsel bestehen;
; scene_frame und die Position der Laufschrift beginnen dagegen bei null.
palette_init:
        out (c),e
        ld a,(hl)
        out (c),a
        inc hl
        inc e
        ld a,e
        cp 16
        jr nz,palette_init
        ld a,16
        out (c),a
        ld a,#54
        out (c),a
        ld a,(scene)
        add a,a
        ld e,a
        ld d,0
        ld hl,scene_lengths
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (scene_length),de
        ld hl,0
        ld (scene_frame),hl
        ld (scroll_pos),hl
        ld a,(scene)
        cp 1
        jr nz,init_not_water
        ld hl,water_packed
        ld de,0
        call LZ48_decrunch
        ld hl,lake_colors
        ld bc,#7f00
        ld e,7
        ld d,6
        call floor_next
; Nur Szene 2 braucht die 32 Phasen der Fahrbahnmarkierung im unteren RAM.
; 32 * 80 Zeilen * 4 Bytes = 10240 Bytes. Sonne und Berge bleiben im Motiv.
; Die beiden anschliessenden Pen-Werte geben der Sonne feste Farben.
init_not_water:
        ld a,(scene)
        cp 2
        jr nz,init_not_road
        ld hl,road_packed
        ld de,0
        call LZ48_decrunch
        ld bc,#7f00
        ld a,5
        out (c),a
        ld a,#4d
        out (c),a
        ld a,6
        out (c),a
        ld a,#5d
        out (c),a
; Die Landschaft braucht zwei identische Rahmenbilder. LDIR kopiert
; #4000 Bytes nach #0000; die erste Seite #c000 bleibt sichtbar.
; back_page=0 bezeichnet die zuerst unsichtbare Seite. Erst ein vollstaendiger
; Durchlauf ueber 64 Spalten gibt sie zur Anzeige frei. Hier darf der
; 16-KiB-Transfer mehrere Frames dauern, weil der Vorhang geschlossen ist.
init_not_road:
        ld a,(scene)
        cp 3
        jr nz,init_not_terrain
        ld hl,#c000
        ld de,0
        ld bc,#4000
        ldir
        xor a
        ld (back_page),a
        ld (terrain_column),a
        ld (terrain_camera),a
        ld hl,terrain_palette
        ld bc,#7f00
        ld e,0
terrain_palette_init:
        out (c),e
        ld a,(hl)
        out (c),a
        inc hl
        inc e
        ld a,e
        cp 16
        jr nz,terrain_palette_init
; Auch Mode 2 startet mit identischen Vorder-/Hintergrundseiten.
; #8e unterscheidet sich von #8c nur in den Modusbits: %10 fuer Mode 2.
; ROMs bleiben aus; sonst verdeckt das untere ROM den zweiten Bildspeicher
; bei CPU-Lesezugriffen. Die Videologik liest unabhaengig davon RAM.
init_not_terrain:
        ld a,(scene)
        cp 5
        jr nz,init_not_moire
        ld hl,#c000
        ld de,0
        ld bc,#4000
        ldir                    ; zwei identische Grundbilder
        xor a
        ld (back_page),a
        ld (moire_row),a
        ld (moire_phase),a
        ld bc,#7f8e
        out (c),c               ; Mode 2, ROMs aus
; Nur im Finale dient der untere RAM als entpackter Scrolltext.
; JP statt CALL + RET ist ein Endaufruf: Das RET des Entpackers geht
; direkt zum Aufrufer von init_scene zurueck.
init_not_moire:
        ld a,(scene)
        cp 6
        ret nz
        ld hl,scroll_packed
        ld de,0
        jp LZ48_decrunch

; Kurzer Vorhang: 13 Frames zum Oeffnen, 13 zum Schliessen.
; Die letzte Szene bleibt nach der vollstaendigen Laufschrift offen.
; VORHANG DURCH R6. R6 zaehlt sichtbare Zeichenzeilen, hier je 8 Rasterzeilen.
; 25 bedeutet 200 sichtbare Zeilen, 0 bedeutet geschlossen. Die Routine
; veraendert nur die sichtbare Hoehe, nicht die Gesamtzahl der Rasterzeilen.
; In den ersten 12 gezeichneten Frames waechst R6 als 2*scene_frame;
; ab Frame 13 gilt 25. Vor dem Szenenende gilt entsprechend 2*Restframes.
; HL/DE dienen der 16-Bit-Restzeitberechnung, A liefert zuletzt R6.
; Szene 6 erhaelt nach dem Oeffnen immer R6=25, damit das Schlussbild bleibt.
shutter:
        ld hl,(scene_frame)
        ld a,h
        or a
        jr nz,shutter_end
        ld a,l
        cp 13
        jr nc,shutter_end
        add a,a
        jr shutter_write
shutter_end:
        ld a,(scene)
        cp 6
        ld a,25
        jr z,shutter_write
        ld hl,(scene_length)
        ld de,(scene_frame)
        or a
        sbc hl,de
        ld a,h
        or a
        ld a,25
        jr nz,shutter_write
        ld a,l
        cp 13
        jr c,shutter_double
        ld a,25
        jr shutter_write
shutter_double:
        add a,a
shutter_write:
        ld e,6
        jp crtc_write

; Die letzten 32 Zeilen bleiben fuer Laufschrift in stabiler Farbe.
; Eintritt nach VSYNC; Pollphase kann wenige Mikrosekunden schwanken.
; CHROM UND SPLIT: Nur Pen 1 wechselt seine Farbe, die Pixelbytes bleiben.
; Die Warteschleife verschiebt den Start vom VSYNC in den sichtbaren Bereich.
; 640 Durchlaeufe kosten ungefaehr 4,48 ms auf dem CPC.
; light_table liegt auf einer 256-Byte-Grenze: H bleibt konstant, L ist
; phase. INC L laeuft nach 255 auf 0, ohne in die naechste Tabelle zu tragen.
; D zaehlt 168 Farbzeilen; in Szene 4 sind es 144 bis zum Mode-2-Unterteil.
raster_effect:
        ld de,640
top_delay:
        dec de
        ld a,d
        or e
        jr nz,top_delay
        ld bc,#7f00
        ld a,1
        out (c),a
        ld a,(phase)
        ld l,a
        ld h,light_table/256
        ld a,(scene)
        cp 4
        ld d,168
        jr nz,raster_line
        ld d,144
; ZEITKRITISCH: Zwischen zwei aufeinanderfolgenden Farb-OUTs liegen
; bei genommenem JR genau 64 us im CPC-Timing:
; LD A,(HL) 2 + OUT 4 + INC L 1 + 53*NOP 53 + DEC D 1 + JR NZ 3.
; DEFS 53,0 legt 53 Opcodebytes #00 ab: Die CPU fuehrt sie als NOP aus.
; Ein hinzugefuegter Befehl verschiebt alle folgenden Farbwechsel.
; Der letzte JR faellt durch; danach setzt #4b den Pen auf helles Weiss.
; Szene 4 schreibt anschliessend #8e: Das Gate Array interpretiert die
; folgenden Bildschirmbytes als acht 1-Bit-Pixel statt zwei 4-Bit-Pixel.
; Der Generator hat den unteren Bildbereich bereits passend gepackt.
raster_line:
        ld a,(hl)                 ; 2 us: naechste Lichtfarbe lesen
        out (c),a                 ; 4 us: Farbwechsel fuer den bereits gewaehlten Pen 1
        inc l                     ; 1 us: Tabellenindex mit 8-Bit-Umlauf
        defs 53,0                 ; 53 us: 53 ausgefuehrte NOPs (#00)
        dec d                     ; 1 us: verbleibende Farbzeilen zaehlen
        jr nz,raster_line        ; exakt 64 us zwischen den OUTs
        ld a,#4b
        out (c),a                 ; 4 us: Farbwechsel fuer den bereits gewaehlten Pen 1
        ld a,(scene)
        cp 4
        ret nz
        ld a,#8e
        out (c),a               ; mitten im Bild: Mode 0 -> Mode 2
        ret

; Spiegelung: 32 unabhaengig verschobene Zeilen, jeweils 80 Bytes.
; Entrolltes LDI spart gegenueber wiederholendem LDIR 1 us pro Byte.
; WASSERSPIEGELUNG. IX zeigt auf 16-Bit-Zeilenoffsets ab Bildschirmzeile 128.
; IY zeigt auf die naechste 96-Byte-Quellzeile im unteren RAM. Jede besteht
; aus 8 Randbytes, 80 Bildbytes und nochmals 8 Randbytes zum Verschieben.
; Der Sinuswert 1..95, viermal rechtsgeschoben, ergibt 0..5; plus 5 also
; Quellversatz 5..10. Der Ausschnitt bleibt stets innerhalb der 96 Bytes.
; 32 Zeilen * 80 LDI * 5 us ergeben 12,8 ms reine Kopierzeit pro Frame.
; Die entrollten LDIs sparen den Wiederholungszuschlag von LDIR.
; BC wird dabei dekrementiert, dient hier aber nicht als Schleifenzaehler.
water_effect:
        ld ix,row_addresses+128*2
        ld iy,0
        ld a,(phase)
        ld (wave_index),a
        ld a,32
        ld (rows_left),a
; HL = IY + horizontaler Quellversatz. PUSH IY / POP HL kopiert den
; Indexregisterwert in HL; danach steht der normale Stack wieder wie zuvor.
; DE = #c000 OR Zeilenoffset aus (IX). Da der Offset kleiner als #4000 ist,
; ueberlappen seine Bits nicht mit der Seitenbasis; OR entspricht Addition.
; 80 LDI lesen fortlaufend von HL und schreiben fortlaufend nach DE.
; IX += 2 geht zur naechsten Bildschirmzeile, IY += 96 zur naechsten Quelle.
; wave_index += 3 veraendert die Wellenphase zwischen benachbarten Zeilen.
water_row:
        ld a,(wave_index)
        ld l,a
        ld h,sine_table/256
        ld a,(hl)
        srl a                     ; Wellenwert halbieren; vier SRL ergeben Division durch 16
        srl a                     ; Wellenwert halbieren; vier SRL ergeben Division durch 16
        srl a                     ; Wellenwert halbieren; vier SRL ergeben Division durch 16
        srl a                     ; Wellenwert halbieren; vier SRL ergeben Division durch 16
        add 5                     ; Ausschnittbeginn im gepolsterten Quellstreifen
        ld e,a
        ld d,0
        push iy
        pop hl
        add hl,de
        ld e,(ix+0)
        ld a,(ix+1)
        or #c0
        ld d,a
        repeat 80
        ldi
        rend
        ld de,96                  ; Schrittweite einer gepolsterten Wasserzeile
        add iy,de                 ; Quelle der naechsten Spiegelungszeile
        inc ix
        inc ix
        ld a,(wave_index)
        add 3
        ld (wave_index),a
        ld a,(rows_left)
        dec a
        ld (rows_left),a
        jp nz,water_row
        ret

; Feste Kamera. Nur acht Pixel der Mittellinie pro Zeile werden kopiert.
; 32 Perspektivphasen, zuerst alle zwei Frames, dann jeder Frame. R13 bleibt null.
; STRASSENBEWEGUNG. Die Bildschirmadresse bleibt konstant (R13=0).
; Solange das Highbyte von scene_frame null ist, teilt SRL A die Zeit durch 2.
; Ab Frame 256 gibt jeder Videoframe die naechste der 32 Phasen frei.
; AND 31 bildet den zyklischen Phasenindex; die Tabelle liegt ab Adresse 0.
; Der Z80 besitzt keine Multiplikation. Sechs ADD HL,HL bilden phase*64;
; DE merkt sich diesen Wert, zwei weitere Verdopplungen ergeben phase*256.
; ADD HL,DE liefert phase*320, den Beginn von 80 Zeilen zu je vier Bytes.
road_effect:
        ld a,(scene_frame+1)      ; Highbyte: ab Frame 256 ungleich null
        or a                      ; Zero-Flag merkt sich die langsame/schnelle Phase
        ld a,(scene_frame)        ; Lowbyte laden, ohne das Zero-Flag zu veraendern
        jr nz,road_fast           ; ab Frame 256 die Halbierung ueberspringen
        srl a                   ; die ersten fuenf Sekunden langsamer
road_fast:
        and 31
        ld (road_phase),a
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl               ; phase*64
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,de               ; phase*320
        ld ix,row_addresses+120*2
        ld a,80
        ld (rows_left),a
; IX liest die Zielzeile 120..199 aus row_addresses. Der Zusatz 38
; waehlt die Byte-Spalten 38..41, also Mode-0-Pixel 76..83 in der Bildmitte.
; PUSH/POP bewahrt HL als Quellzeiger waehrend der Zieladressrechnung.
; Vier LDI schreiben genau diese acht Pixel. 80 Zeilen brauchen 320 Bytes;
; die uebrige Grafik bleibt unangetastet. Danach folgen passende Randfarben.
road_row:
        ld e,(ix+0)
        ld a,(ix+1)
        or #c0
        ld d,a
        push hl
        ld hl,38
        add hl,de
        ex de,hl
        pop hl
        repeat 4
        ldi
        rend
        inc ix
        inc ix
        ld a,(rows_left)
        dec a
        ld (rows_left),a
        jr nz,road_row
        ; Passende Bewegungsphase fuer die acht Bordsteinfarben.
        ld a,(road_phase)
        srl a
        srl a
        ld l,a
        ld h,0
        ld de,road_colors
        add hl,de
        ld bc,#7f00
        ld e,7
        ld d,8
; E=7..14 sind acht vorbereitete Farbklassen an den Bordsteinen.
; HL liest acht Werte aus road_colors, beginnend bei floor(road_phase/4).
; Die Tabelle enthaelt zwei gleiche Achtergruppen, damit dieser Ausschnitt
; ohne Sonderfall ueber das Ende der ersten Gruppe laufen darf.
; Farbrotation bewegt so die Bordsteine ohne Kopieren ihrer Pixel.
road_palette:
        out (c),e
        ld a,(hl)
        out (c),a
        inc hl
        inc e
        dec d
        jr nz,road_palette
        ret

; Mode 2: 640x200, zwei Farben. 32 neue Zeilen je Videoframe,
; 128 Zeilen je Musterbild. CRTC-Seitenwechsel erst nach fertigem Bild.
; Tabelle enthaelt acht Pixelphasen einer nichtlinearen Linienstruktur.
; MODE-2-INTERFERENZ. Veraendert AF, BC, DE und HL sowie die Arbeitsbytes.
; 32 Zeilen je Aufruf, 128 Zeilen je fertigem Muster: Umschaltung alle 4 Frames.
; moire_row ist die Zeile 0..127 innerhalb des Fensters, Bildschirm-y ist +36.
; back_page ist das Highbyte der unsichtbaren Seite (#00 oder #c0).
; Die Schriftbereiche ausserhalb des Fensters bleiben in beiden Seiten gleich.
moire_effect:
        ld a,32
        ld (rows_left),a
; Zieladresse zuerst bestimmen, dann auf dem Stack sichern.
; Der Index 2*(moire_row+36) kann 255 ueberschreiten. ADD A,A liefert das
; neunte Bit in Carry. LD L,A und LD H,0 erhalten Carry; INC H setzt es
; bei Bedarf als Highbyte des Tabellenoffsets um.
moire_row_loop:
        ld a,(moire_row)
        add 36                    ; Fenster beginnt in Bildschirmzeile 36
        add a,a                   ; Wortindex; Carry traegt das neunte Adressbit
        ld l,a
        ld h,0                    ; LD veraendert Carry nicht
        jr nc,moire_addr          ; ohne Ueberlauf passt der Index ins Lowbyte
        inc h                     ; sonst Highbyte des Tabellenoffsets auf 1 setzen
; row_addresses liefert den Offset; OR back_page ergaenzt dessen Seite.
; Der Sinusindex lautet (2*moire_row + moire_phase) modulo 256.
; Die Amplitude waechst zeitlich: Frames 0..127 Viertelwert, 128..255
; Halbwert, danach voller Wert. Das macht die Verformung allmaehlich staerker.
moire_addr:
        ld de,row_addresses
        add hl,de
        ld e,(hl)
        inc hl
        ld a,(back_page)
        or (hl)
        ld d,a
        push de
        ld a,(moire_row)
        add a,a
        ld b,a
        ld a,(moire_phase)
        add a,b
        ld l,a
        ld h,sine_table/256
        ld a,(hl)
        ld b,a
        ld a,(scene_frame+1)
        or a
        ld a,b
        jr nz,moire_amplitude
        srl a
        ld b,a
        ld a,(scene_frame)
        bit 7,a
        ld a,b
        jr nz,moire_amplitude
        srl a
; Der Wert B steuert Feinauswahl und Byteversatz. Seine unteren drei Bits
; waehlen eine von acht Pixelphasen. Jede Variante belegt 512 Bytes:
; 256 Musterbytes und eine identische zweite Haelfte fuer randlose Ausschnitte.
; (Phase AND 7)*2 addiert die passende Zahl von 256-Byte-Seiten zu H.
; L=(moire_row+B) modulo 256 waehlt den Anfang innerhalb der Variante.
; Ein 80-Byte-LDI-Ausschnitt passt dank der doppelten Ablage auch ab Offset 255.
; Erst nach Zeile 127 schreibt R12 die fertige Seite. RRCA zweimal bildet
; #c0 -> #30 bzw. #00 -> #00. XOR #c0 wechselt danach die Arbeitsseite.
moire_amplitude:
        ld b,a
        and 7
        add a,a
        add a,moire_patterns/256
        ld h,a
        ld a,(moire_row)
        add a,b
        ld l,a
        pop de
        repeat 80
        ldi
        rend
        ld a,(moire_row)
        inc a
        ld (moire_row),a
        ld a,(rows_left)
        dec a
        ld (rows_left),a
        jp nz,moire_row_loop
        ld a,(moire_row)
        cp 128
        ret nz
        xor a
        ld (moire_row),a
        ld a,(back_page)
        rrca
        rrca
        ld e,12
        call crtc_write
        ld a,(back_page)
        xor #c0
        ld (back_page),a
        ld a,(moire_phase)
        add 3
        ld (moire_phase),a
        ret

; Eine breite Pixelschrift bewegt sich um zwei Mode-0-Pixel pro Bild.
; Ihr entpackter Spaltenstrom liegt nur im Finale bei &0000.
; LAUFSCHRIFT IM FINALE. scroll_pos ist ein Byteoffset in der Quelle.
; Der Strom speichert pro horizontaler Schriftspalte sieben Bytes,
; eines fuer jede der sieben Pixelzeilen. Ein Byte enthaelt zwei gleiche
; Mode-0-Pixel. Pro Frame wandert die Schrift deshalb zwei Pixel nach links.
; Bei scroll_pos >= scroll_size endet die Routine sofort. Der Generator
; haengt Leerzeichen an; am Ende ist der gesamte Scrollstreifen leer.
scroll_tick:
        ld hl,(scroll_pos)
        ld de,scroll_size
        or a
        sbc hl,de
        ret nc
        ld ix,row_addresses+176*2
        ld iy,(scroll_pos)
        ld a,7
        ld (rows_left),a
; DE zeigt auf Byte 0 der Zielzeile, HL auf Byte 1 derselben Zeile.
; 79 LDI schieben die Zeile um ein Byte nach links. Die Kopierrichtung ist
; sicher: Die Quelle liegt immer ein Byte vor dem Ziel, kein spaeter noch
; benoetigtes Quellbyte wird ueberschrieben. DE endet auf dem rechten Rand.
; Dorthin kommt (IY), das naechste Byte dieser Schriftspalte. IY waechst
; pro Pixelzeile um eins; scroll_pos waechst erst nach sieben Zeilen um 7.
scroll_row:
        ld e,(ix+0)
        ld a,(ix+1)
        or #c0
        ld d,a
        ld h,d
        ld l,e
        inc hl
        repeat 79
        ldi
        rend
        ld a,(iy+0)
        ld (de),a
        inc iy
        inc ix
        inc ix
        ld a,(rows_left)
        dec a
        ld (rows_left),a
        jp nz,scroll_row
        ld hl,(scroll_pos)
        ld de,7
        add hl,de
        ld (scroll_pos),hl
        ret

; AY-Register A mit E beschreiben. Port-C-Unterbits bleiben null.
; AY-HELFER. Eingabe A=AY-Registernummer, E=Datenwert.
; Veraendert BC; erhaelt AF, DE, HL, IX und IY. Die Folge besteht nur aus
; LD, OUT und RET, daher bleiben auch die Flags erhalten.
; PPI A liefert den AY-Datenbus. PPI C Bit 7 ist BDIR, Bit 6 ist BC1:
; #c0 = 11 adressiert ein Register, #80 = 10 schreibt dessen Daten,
; #00 = 00 beendet die jeweilige Busphase. Der AY erzeugt danach selbst
; Ton; die CPU muss keine einzelnen Schwingungen nachbilden.
; Port-C-Unterbits bleiben null: Tastaturzeile 0, Kassettenmotor und
; Kassetten-Ausgang aus. Dieser Player bedient keine Tastaturabfrage.
ay_write:
        ld bc,#f400               ; PPI-Port A als AY-Datenbus
        out (c),a                 ; AY-Registernummer auf den Datenbus legen
        ld bc,#f6c0               ; Port C, BDIR=1 und BC1=1
        out (c),c                 ; aktuellen Steuerwert C ausgeben (Phase oder Ruhe)
        ld c,0                    ; Steuerwert null; der Port bleibt #f6xx
        out (c),c                 ; aktuellen Steuerwert C ausgeben (Phase oder Ruhe)
        ld b,#f4                  ; zurueck zu Port A, C bleibt 0
        out (c),e                 ; Registerwert auf den AY-Datenbus legen
        ld bc,#f680               ; Port C, BDIR=1 und BC1=0 fuer Schreibphase
        out (c),c                 ; aktuellen Steuerwert C ausgeben (Phase oder Ruhe)
        ld c,0                    ; Steuerwert null; der Port bleibt #f6xx
        out (c),c                 ; aktuellen Steuerwert C ausgeben (Phase oder Ruhe)
        ret

; Lautstaerke sinkt im Finale waehrend der letzten 32 Bilder.
; AUSBLENDEN. Nur im Finale und nur bei weniger als 32 Restframes.
; volume_limit = floor(Restframes/2), also absteigend bis 0.
; Der Aufruf folgt music_tick; die neue Grenze wirkt deshalb beim
; naechsten Musikaufruf. show_complete setzt die Kanaele abschliessend stumm.
ending_volume:
        ld a,(scene)
        cp 6
        ret nz
        ld hl,(scene_length)
        ld de,(scene_frame)
        or a                      ; Carry fuer die folgende 16-Bit-Subtraktion loeschen
        sbc hl,de                 ; Restframes = Szenenlaenge - bisherige Frames
        ld a,h
        or a                      ; Highbyte der Restzeit auf null pruefen
        ret nz
        ld a,l
        cp 32
        ret nc
        srl a                     ; zwei Frames je Lautstaerkestufe
        ld (volume_limit),a
        ret
; LAUTSTAERKE MIT GRENZE. Eingabe A=8/9/10, E=gewuenschter Pegel 0..15.
; Bei R10 (Kanal C) teilen See und Split den Pegel zusaetzlich durch 4.
; AF wird vor dem Vergleich gesichert, weil A die AY-Registernummer traegt.
; CP E prueft volume_limit gegen E. Falls E groesser ist, ersetzt die
; Routine E durch die Grenze. Endaufruf von ay_write ueber JP.
volume_write:
        cp 10
        jr nz,volume_common
        ld a,(scene)
        cp 1
        jr z,drums_quiet
        cp 4
        jr nz,drums_full
drums_quiet:
        srl e
        srl e
drums_full:
        ld a,10
volume_common:
        push af                   ; AY-Registernummer und Flags ueber Vergleich retten
        ld a,(volume_limit)
        cp e                      ; Grenze mit angefordertem Pegel vergleichen
        jr nc,volume_keep         ; Grenze >= Pegel: E kann unveraendert bleiben
        ld e,a                    ; sonst auf die globale Grenze begrenzen
volume_keep:
        pop af                    ; AY-Registernummer wiederherstellen
        jp ay_write               ; Endaufruf: RET des Helfers geht direkt zum Aufrufer

; Eigene Komposition: 128 Sechzehntel, acht Frames pro Schritt.
; A Arpeggio, B pulsierender Bass, C Kick/Snare/Hi-Hat.
; MUSIK OHNE FIRMWARE. beat_frame zaehlt 0..7 innerhalb einer Note;
; song_step zaehlt die 128 Notenschritte. Ein Schritt dauert etwa 159,7 ms.
; Die Tabellen enthalten 16-Bit-Perioden, keine Frequenzen. Beim AY mit
; 1-MHz-Takt gilt fuer die Tonkanaele f = 1000000 / (16 * Periode).
; R0/R1 setzen Periode A, R2/R3 Periode B. Nur bei beat_frame=0 kommen
; neue Tonhoehen; die Lautstaerkekurven erhalten trotzdem jeden Frame Updates.
; E transportiert jeweils das Low- oder Highbyte an ay_write. Dieser
; Helfer erhaelt HL, daher kann der Notenzeiger zwischen den Writes bleiben.
music_tick:
        ld a,(beat_frame)
        or a
        jr nz,music_envelope
        ld a,(song_step)
        add a,a                   ; zwei Periodenbytes pro Notenschritt
        ld e,a
        ld d,0
        ld hl,lead_notes
        add hl,de
        push de                   ; Tabellenoffset fuer die anschliessende Bassnote sichern
        ld e,(hl)
        xor a                     ; AY R0: Lowbyte Tonperiode A
        call ay_write
        inc hl
        ld e,(hl)
        ld a,1                    ; AY R1: Highbyte Tonperiode A
        call ay_write
        pop de
        ld hl,bass_notes
        add hl,de
        ld e,(hl)
        ld a,2                    ; AY R2: Lowbyte Tonperiode B
        call ay_write
        inc hl
        ld e,(hl)
        ld a,3                    ; AY R3: Highbyte Tonperiode B
        call ay_write
; Software-Huellkurven: A faellt von 14 auf 7; B von 12 auf 9.
; Bit 4 der AY-Pegelregister bleibt null, also feste Pegel statt der
; Hardware-Huellkurve. Die Instrumentform entsteht durch diese Frame-Updates.
; song_step modulo 4 verteilt Kick, Hi-Hat, Snare, Hi-Hat auf Kanal C.
music_envelope:
        ld a,(beat_frame)
        ld e,a
        ld a,14
        sub e
        ld e,a
        ld a,8
        call volume_write
        ld a,(beat_frame)
        srl a
        ld e,a
        ld a,12
        sub e
        ld e,a
        ld a,9
        call volume_write
        ld a,(song_step)
        and 3
        jr z,kick
        cp 2
        jr z,snare
        ld e,2
        jr noise_drum
snare:
        ld e,14
; R6 ist die Rauschperiode: 2 fuer kurze Hi-Hat, 14 fuer Snare.
; R7=#1c: Ton A/B an, Ton C aus; Rauschen A/B aus, Rauschen C an.
; In den sechs unteren Mixerbits bedeutet 1 jeweils DEAKTIVIERT.
; Die hier null gesetzten Port-Richtungsbits sind keine Lautstaerkebits.
noise_drum:
        ld a,6
        call ay_write
        ld a,7
        ld e,#1c
        call ay_write
        jr drum_volume
; R7=#38: drei Tonkanaele an, alle Rauschpfade aus.
; Kanal C erhaelt Lowbyte 0, Highbyte beat_frame+3. Die Periode waechst
; von #0300 bis #0a00, die Frequenz sinkt: kurzer abfallender Bassdrum-Ton.
kick:
        ld a,7
        ld e,#38
        call ay_write
        ld a,(beat_frame)
        add 3
        ld e,a
        ld a,5
        call ay_write
        ld a,4
        ld e,0
        call ay_write
; Schlagzeugpegel 14 - 2*beat_frame: 14,12,...,0.
; AND 7 setzt beat_frame nach acht Aufrufen auf null. Nur dann laeuft
; song_step weiter; AND 127 laesst die 128-Schritt-Komposition wiederholen.
 drum_volume:
        ld a,(beat_frame)
        add a,a
        ld e,a
        ld a,14
        sub e
        ld e,a
        ld a,10
        call volume_write
        ld a,(beat_frame)
        inc a
        and 7
        ld (beat_frame),a
        ret nz
        ld a,(song_step)
        inc a
        and 127
        ld (song_step),a
        ret

; BODENLICHT DURCH PALETTE. Dreimal RRCA und AND 15 ergeben
; (phase >> 3) AND 15. Aus der wiederholten Farbliste wandert dadurch ein
; Fenster von sechs Eintraegen, ein Schritt pro acht Videoframes.
; Die Bildbytes bleiben gleich. Pens 7..12 wechseln ihre Hardwarefarbe.
floor_tick:
        ld a,(phase)
        rrca
        rrca
        rrca
        and 15                    ; 16 Startpositionen in der wiederholten Farbliste
        ld l,a
        ld h,0
        ld de,floor_colors
        add hl,de
        ld bc,#7f00
        ld e,7                    ; erster zu aendernder Pen
        ld d,6                    ; sechs Pens fuer die Bodenlinien
; Gemeinsame Palettenschleife, auch fuer die Initialisierung des Sees.
; E = erster Pen, D = Anzahl, HL = Farbcodes, BC = #7f00.
; Veraendert A, DE, HL und Flags; BC bleibt fuer beide OUTs gleich.
floor_next:
        out (c),e
        ld a,(hl)
        out (c),a
        inc hl
        inc e
        dec d
        jr nz,floor_next
        ret

; Hoehenfeld mit 64x64 Hoehen, 16 Tiefenstufen und 64 Bildspalten.
; Jeder Block umfasst zwei Mode-0-Pixel und vier Rasterzeilen.
; 64x32 logische Bloecke fuellen ein Fenster von 128x128 Mode-0-Pixeln.
; 8 Spalten pro Videoframe: 8 Frames pro fertigem Landschaftsbild.
terrain_state equ #b800         ; 16 Paare aus Karten-/Projektionsadresse
; LANDSCHAFT: acht Spalten je Videoframe in den unsichtbaren Bildspeicher.
; Bei Spalte 0 bereitet terrain_prepare die Adressliste fuer diesen
; Kamerastand vor. Diese Liste gilt fuer alle 64 Spalten desselben Bildes.
; Nach Spalte 63 setzt R12 die Startadresse der fertigen Seite; die andere
; Seite wird Arbeitsseite. Dann rueckt die Kamera eine Kartenzeile vor.
; 64 Kamerastaende * 8 Frames ergeben die komplette 512-Frame-Szene.
terrain_effect:
        ld a,(terrain_column)
        or a
        call z,terrain_prepare
        ld a,8
        ld (terrain_batch),a
terrain_batch_loop:
        call terrain_draw_column
        ld a,(terrain_column)
        inc a
        ld (terrain_column),a
        ld a,(terrain_batch)
        dec a
        ld (terrain_batch),a
        jr nz,terrain_batch_loop
        ld a,(terrain_column)
        cp 64
        ret nz
        xor a
        ld (terrain_column),a
        ld a,(back_page)
        rrca
        rrca
        ld e,12
        call crtc_write
        ld a,(back_page)
        xor #c0
        ld (back_page),a
        ld a,(terrain_camera)
        inc a
        and 63
        ld (terrain_camera),a
        ret

; Nur einmal je Landschaftsbild. Adressstrom fuer POP DE vorbereiten.
; ADRESSLISTE ERZEUGEN. terrain_camera ist die Welt-Zeile 0..63.
; terrain_track[camera] liefert die seitliche Kameraposition terrain_x.
; HL schreibt ab #b800, IY liest die 16 Tiefenabstaende, BC zeigt auf die
; aktuelle Projektionszeile. Jeder Listeneintrag ist vier Bytes lang:
; [Low(Kartenzeile), High(Kartenzeile), Low(Projektionszeile), High(...)]
; POP DE wird spaeter genau diese Little-Endian-Woerter lesen.
; Diese Vorbereitung benutzt noch den normalen Stack und darf CALL/RET nutzen.
terrain_prepare:
        ld a,(terrain_camera)
        ld e,a
        ld d,0
        ld hl,terrain_track
        add hl,de
        ld a,(hl)
        ld (terrain_x),a
        ld hl,terrain_state
        ld iy,terrain_depths
        ld bc,terrain_projection
        ld a,16
        ld (terrain_count),a
; Weltzeile z = (camera + Tiefenabstand) AND 63.
; Die Kartenadresse ist terrain_map + z*64. Fuer das Lowbyte genuegen
; zwei RRCA und AND #c0: Nur die untersten zwei Bits von z landen oben.
; Das Highbyte erhaelt z >> 2 plus das Highbyte der 256-Byte-ausgerichteten
; Karte. Beispiel z=5: Offset #0140, Low=#40, High-Zuschlag=1.
; Die Projektionszeile enthaelt 64 Hoehenwerte je Tiefe. BC waechst daher
; um 64; bei Lowbyte-Ueberlauf erhoeht INC B explizit das Highbyte.
terrain_prepare_depth:
        ld a,(terrain_camera)
        add a,(iy+0)
        and 63
        ld e,a
        rrca
        rrca
        and #c0
        ld (hl),a
        inc hl
        ld a,e
        srl a
        srl a
        add a,terrain_map/256
        ld (hl),a
        inc hl
        ld (hl),c
        inc hl
        ld (hl),b
        inc hl
        ld a,c
        add 64
        ld c,a
        jr nc,terrain_projection_page
        inc b
terrain_projection_page:
        inc iy
        ld a,(terrain_count)
        dec a
        ld (terrain_count),a
        jr nz,terrain_prepare_depth
        ret

; EINE SPALTE VON NAH NACH FERN. Hauptregister:
; HL = aktuelles Zielpixel (wir zeichnen von unten nach oben),
; DE = nacheinander Kartenadresse, Projektionsadresse, Farbadresse;
; B = Zahl der zu zeichnenden Vierergruppen, C = fertiges Pixelbyte,
; E beim Fuellen = Vierergruppen bis zum naechsten 8-Zeilen-RAM-Sprung.
; Alternativregister: HL' = X-Abtasttabelle, B' = verbleibende Tiefenpunkte.
; EXX tauscht BC/DE/HL mit ihren Alternativen; A und Flags wechseln NICHT.
; IXL haelt kurz die Abschnittslaenge. IX ist in dieser Szene kein Zeiger.
; 
; terrain_samples hat 16 Bytes je Bildspalte. Vier ADD HL,HL bilden
; Spalte*16. PUSH HL, EXX, POP HL uebertraegt den Zeiger nach HL'.
; terrain_top=128 bedeutet: Bisher verdeckt noch kein naher Huegel die Spalte.
; Fenster: Byte-Spalten 8..71, Bildschirmzeilen 48..175. Start unten:
; Offset(175)=#3e90; +8+Spalte ergibt Lowbyte #98+Spalte (kein Ueberlauf).
; 
; SP-TRICK: Vor dem Umstellen speichert LD (restore_terrain_sp+1),SP
; den normalen Stackwert direkt in die beiden Operandenbytes von LD SP,nn.
; Das Opcodebyte bleibt unveraendert. Der Code muss deshalb im RAM liegen.
; Ab LD SP,terrain_state sind CALL, PUSH und RET bis zur Wiederherstellung
; verboten: Sie wuerden die Adressliste oder den Ruecksprung zerstoeren.
; DI sperrt maskierbare Interrupts, aber keinen NMI. Waehrend dieser Phase
; darf eine Erweiterung keinen NMI ausloesen. Jeder POP DE liest zwei Bytes
; und erhoeht SP um 2.
terrain_draw_column:
        ld a,(terrain_column)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,terrain_samples
        add hl,de
        push hl
        exx
        pop hl                  ; HL' laeuft durch die 16 X-Abtastwerte
        ld b,16                 ; B' ist der Tiefenzaehler
        exx
        ld a,128
        ld (terrain_top),a
        ld a,(terrain_column)
        add #98                 ; y=175: Offset #3e90 plus linker Rand 8
        ld l,a
        ld a,(back_page)
        or #3e
        ld h,a
        ld (restore_terrain_sp+1),sp ; Rueckkehr-Stack in den LD-SP-Operanden schreiben
        ld sp,terrain_state       ; ab jetzt zeigt SP auf die Adressliste statt auf Rueckspruenge
; X = (Kamera-X + vorberechneter seitlicher Abstand) modulo 64.
; POP DE liefert die Kartenzeile. Ihre unteren sechs Adressbits sind null,
; daher verbindet OR E Zeilenbasis und X ohne Carry: gleichwertig zu +X.
; Das gelesene Hoehenbyte liegt in 0..63. Der zweite POP liefert die ebenso
; auf 64 Bytes ausgerichtete Projektionszeile; OR E fuegt die Hoehe hinzu.
; Die Projektionstabelle erspart der CPU die Division durch Entfernung:
; y = clamp(4*round((20 + (55-Hoehe)*80/Tiefe)/4), 0, 128).
; Alle y-Werte sind Vielfache von vier. 55 ist die Kamerahoehe im Generator.
; 
; terrain_top ist die obere Grenze des bereits gefuellten unteren Abschnitts.
; Ist y >= terrain_top, verdeckt ein naeherer Punkt diesen Fernpunkt.
; Sonst zeichnen wir [y, terrain_top), also genau (terrain_top-y)/4 Gruppen.
; Zwei SRL teilen durch vier. IXL bewahrt die Laenge ohne Stackzugriff.
; Der neue terrain_top-Wert ist y. Die Farbtabelle hat dasselbe Layout wie
; die Projektion und folgt 1024 Bytes spaeter: D+4 waehlt dieselbe Zelle dort.
; C erhaelt schon ein vollstaendig gepacktes Mode-0-Byte fuer zwei gleiche Pens.
terrain_sample:
        exx
        ld a,(hl)
        exx
        ld c,a
        ld a,(terrain_x)
        add a,c
        and 63
        pop de                  ; Kartenzeile statt langsamer Indexzugriffe
        or e                      ; disjunkte Bitfelder verbinden: Zeilenbasis + Index
        ld e,a
        ld a,(de)               ; tatsaechliche Welthoehe
        pop de                  ; Projektionszeile fuer diese Entfernung
        or e                      ; disjunkte Bitfelder verbinden: Zeilenbasis + Index
        ld e,a
        ld a,(de)               ; projiziertes Y, bereits auf 0..128 begrenzt
        ld b,a
        ld a,(terrain_top)
        sub b                     ; alte Oberkante minus neues y; Carry/Zero bedeuten verdeckt
        jr c,terrain_next_depth   ; neues y liegt tiefer: naher Huegel verdeckt es
        jr z,terrain_next_depth ; hinter dem bereits sichtbaren Hoehenzug
        srl a                     ; Abschnittslaenge halbieren; zweimal teilen ergibt Vierergruppen
        srl a                   ; vier Rasterzeilen je Hoehenstufe
        ld ixl,a                ; Abschnittslaenge; POP-Lesestrom bleibt unveraendert
        ld a,(terrain_top)
        dec a
        and 7
        srl a                     ; Rasterposition innerhalb des 8-Zeilen-Blocks halbieren
        srl a                     ; weiter auf Vierergruppen umrechnen
        inc a
        ld c,a                  ; 1 oder 2 Vierergruppen bis zum 8-Zeilen-Sprung
        ld a,b
        ld (terrain_top),a
        ld a,d
        add 4                   ; Farbtabelle liegt 1024 Bytes hinter Projektion
        ld d,a
        ld a,(de)
        ld e,c
        ld c,a                  ; zwei identische Mode-0-Pixel
        ld b,ixl                ; Abschnittslaenge in Vierergruppen
; VIER RASTERZEILEN PRO SCHLEIFE. LD (HL),C zeichnet zwei Pixel.
; Innerhalb eines 8-Zeilen-Blocks liegt die vorherige Rasterzeile #0800 Bytes
; niedriger. SUB 8 am Highbyte setzt genau diesen Adressschritt um.
; Nach vier Schreibzugriffen zeigt HL auf die naechste noch freie Zeile.
; E zaehlt bis zum Uebergang von Zeile 0 zur Zeile 7 des vorherigen Blocks.
; Dort muss die Adresse zusaetzlich um #4000-80 korrigiert werden:
; SUB 80 am Lowbyte und SBC A,#c0 am Highbyte addieren zusammen #3fb0.
; SBC uebernimmt den Borrow des Lowbytes. Beispiel relativ zur Seite:
; Nach y=168 wurde #0690 beschrieben; der normale Schritt ergibt #fe90.
; Die Korrektur #3fb0 fuehrt modulo 65536 zu #3e40, der Adresse von y=167.
; B zaehlt Gruppen. DJNZ beeinflusst die Flags nicht; E startet danach mit 2.
terrain_span:
        ld (hl),c
        ld a,h
        sub 8
        ld h,a
        ld (hl),c
        sub 8
        ld h,a
        ld (hl),c
        sub 8
        ld h,a
        ld (hl),c
        sub 8
        ld h,a
        dec e
        jr nz,terrain_same_row
        ld a,l
        sub 80
        ld l,a
        ld a,h
        sbc a,#c0               ; +64 minus Uebertrag der unteren Adresse
        ld h,a
        ld e,2
terrain_same_row:
        djnz terrain_span
; EXX macht den Abtastzeiger HL' und Tiefenzaehler B' erreichbar.
; INC HL geht zum naechsten X-Abstand, DEC B setzt das Zero-Flag fuer
; 16 abgearbeitete Punkte. Das folgende EXX erhaelt dieses Flag.
; JP NZ kann deshalb trotz Registerwechsel auf den Tiefenzaehler reagieren.
; Auch verdeckte Punkte haben ihre beiden POPs ausgefuehrt. SP steht
; nach 16 Punkten immer bei #b840; der Lesestrom bleibt synchron.
terrain_next_depth:
        exx                       ; BC/DE/HL tauschen, Flags und A bleiben unveraendert
        inc hl                    ; naechsten seitlichen Abtastwert anwaehlen
        dec b                     ; Tiefenzaehler im alternativen Registersatz vermindern
        exx                       ; BC/DE/HL tauschen, Flags und A bleiben unveraendert
        jp nz,terrain_sample      ; Zero-Flag stammt weiterhin von DEC B
; Dieser LD-SP-Operand enthaelt jetzt den vorhin gesicherten echten SP.
; Er zeigt noch auf die Ruecksprungadresse von CALL terrain_draw_column.
; Erst ab hier sind RET und normale Stackzugriffe wieder zulaessig.
; Ueber der hoechsten sichtbaren Kante bleiben terrain_top Rasterzeilen
; Himmel. Wir fuellen sie schwarz, damit das vorige Kamerabild verschwindet.
; Bei terrain_top=0 ist bereits die ganze Spalte fertig. Sonst teilt SRL
; zweimal durch vier; (Gruppenzahl-1) AND 1 plus 1 setzt den RAM-Sprungzaehler.
restore_terrain_sp:
        ld sp,0                 ; selbstmodifiziert; IRQs bleiben deaktiviert
        ld a,(terrain_top)
        or a
        ret z
        srl a                     ; Himmelshoehe halbieren; zwei SRL ergeben Gruppenzahl
        srl a                     ; Himmelshoehe halbieren; zwei SRL ergeben Gruppenzahl
        ld b,a
        dec a
        and 1                     ; Restgruppe innerhalb des 8-Rasterzeilen-Blocks
        inc a
        ld e,a
        ld c,0                    ; Schwarz fuer beide Mode-0-Pixel
; Gleicher Vierzeilenlauf wie terrain_span, jetzt mit C=0 fuer Schwarz.
; HL setzt nahtlos oberhalb der letzten Landschaftsflaeche fort.
; Jede Spalte erhaelt insgesamt 128 Rasterzeilen: sichtbare Hoehenabschnitte
; und restlichen Himmel. Es gibt keine separate Vollbild-Loeschschleife.
terrain_sky:
        ld (hl),c
        ld a,h
        sub 8
        ld h,a
        ld (hl),c
        sub 8
        ld h,a
        ld (hl),c
        sub 8
        ld h,a
        ld (hl),c
        sub 8
        ld h,a
        dec e
        jr nz,terrain_sky_row
        ld a,l
        sub 80
        ld l,a
        ld a,h
        sbc a,#c0
        ld h,a
        ld e,2
terrain_sky_row:
        djnz terrain_sky
        ret

; Der LZ48-Entpacker nutzt IXL als Token-Register. Das ist hier ein
; konkreter Einsatz einer undokumentierten Z80-Indexhaelfte.
; ENTPACKEN: Eingabe HL=komprimierte Quelle, DE=Ziel. Veraendert AF,
; BC, DE, HL und IXL. IX als ganzer Zeiger ist danach ebenfalls veraendert.
; Der Entpacker kopiert zuerst ein Literalbyte. Danach steuert ein Token
; Literal-Laenge (oberes Halbbyte) und Wiederholungslaenge (unteres Halbbyte).
; Zusatzbytes verlaengern diese Laengen; Matches haben mindestens 3 Bytes.
; Ein Offsetbyte verweist auf schon erzeugte Zielbytes. Vorwaerts-LDIR
; erlaubt dabei ueberlappende Kopien fuer wiederholte Muster.
; Offsetbyte #ff wird durch INC A zu null und beendet den Strom per RET Z.
; Der Entpacker speichert das Token in IXL, waehrend A Laengen berechnet.
; Er liefert DE auf das Byte hinter der Ausgabe und HL auf das Endbyte
; der Quelle. Die Aufrufer setzen ihre anderen Arbeitsregister danach neu.
; Die Originaldatei bleibt eingebunden; unsere Erlaeuterung aendert sie nicht.
        include '../tools/rasm/decrunch/lz48decrunch_v006b.asm'
; VERAENDERLICHER ZUSTAND. Bytewerte folgen als DB, Wortwerte als DW.
; Tests erlauben Aenderungen genau bis mutable_end sowie an den beiden
; Operandenbytes von restore_terrain_sp. Alle anderen Programmdaten
; muessen waehrend der Show unveraendert bleiben.
volume_limit:   db 15             ; Obergrenze 0..15 fuer alle Musikpegel
scene:          db 0              ; aktuelle Szene 0..6
scene_frame:    dw 0              ; Videoframes seit Szenenbeginn, 16 Bit
phase:          db 0              ; globaler Animationszaehler, Umlauf nach 256
finished:       db 0              ; 1 nach Schlussakkord und letztem Szenenframe
beat_frame:     db 0              ; 0..7 innerhalb eines Notenschritts
song_step:      db 0              ; 0..127 in der Notentabelle
wave_index:     db 0              ; Sinusphase innerhalb des Spiegelungsfensters
rows_left:      db 0              ; gemeinsamer Arbeitszaehler fuer Zeilenschleifen
moire_row:      db 0              ; naechste Musterzeile 0..127
moire_phase:    db 0              ; Verformungsphase; +3 je fertigem Musterbild
back_page:      db 0              ; Highbyte der unsichtbaren Seite: #00 oder #c0
scroll_pos:     dw 0              ; Byteoffset der naechsten Sieben-Byte-Schriftspalte
scene_length:   dw 0              ; Sollzahl der Frames fuer die aktuelle Szene
road_phase:     db 0              ; Fahrbahnphase 0..31
terrain_column: db 0              ; naechste Spalte 0..63 auf der Arbeitsseite
terrain_camera: db 0              ; Kamera-Z / Tabellenphase 0..63
terrain_top:    db 0              ; erste bereits gefuellte Zeile, relativ zum Fenster
terrain_x:      db 0              ; seitliche Kameraposition aus terrain_track
terrain_batch:  db 0              ; noch zu zeichnende Spalten dieses Frames, anfangs 8
terrain_count:  db 0              ; Tiefenpunkte bei der Adressvorbereitung, anfangs 16
; Ab hier folgen unveraenderliche Tabellen. Die Szenenlaengen ergeben
; zusammen 3072 Videoframes; Entpackpausen kommen zur Showdauer hinzu.
mutable_end:
lake_colors:    db #44,#58,#5d,#4d,#4f,#4b
scene_lengths:  dw 384,384,512,512,128,512,640
terrain_palette: db #54,#44,#55,#46,#56,#5a,#59,#52,#5e,#43,#4b,#58,#5d,#5b,#4f,#4b
road_colors:    db #4b,#4b,#4b,#4b,#4d,#4d,#4d,#4d
                db #4b,#4b,#4b,#4b,#4d,#4d,#4d,#4d
; CRTC-REGISTERWERTE IN REIHENFOLGE R0..R13:
; R0=63: 64 Zeichenzeiten je Zeile; R1=40: 40 sichtbar (=80 Bytes).
; R2=46: horizontale Syncposition; R3=#8e: Syncbreiten, CRTC-abhaengige Wirkung.
; R4=38: 39 Zeichenzeilen gesamt; R5=0: keine zusaetzlichen Rasterzeilen.
; R6=0: anfangs unsichtbar; R7=30: vertikale Syncposition.
; R8=0: regulare progressive Darstellung ohne Interlace/Skew.
; R9=7: acht Rasterzeilen je Zeichenzeile; 39*8 ergibt 312 Gesamtzeilen.
; R10/R11=0: Cursorparameter, fuer diese Bitmapdarstellung ohne Nutzen.
; R12=#30, R13=0: Bildstart auf CPU-RAM-Seite #c000.
crtc_defaults:  db 63,40,46,142,38,0,0,30,0,7,0,0,48,0
initial_palette: incbin '../assets/palette.bin'
floor_colors:   db #44,#58,#5d,#4f,#4b,#4f,#5d,#58
                db #44,#58,#5d,#4f,#4b,#4f,#5d,#58
                db #44,#58,#5d,#4f,#4b,#4f,#5d,#58
lead_notes:     incbin '../assets/lead.bin'
bass_notes:     incbin '../assets/bass.bin'
; 224 Zeilenoffsets als Little-Endian-Woerter. Die gemeinsame Formel
; steht im Dateikopf. Die Seite wird erst beim Zeichnen per OR ergaenzt.
; Die zusaetzlichen 24 Eintraege ueber 200 hinaus bleiben hier unbenutzt.
row_addresses:  incbin '../assets/rows.bin'
pictures:       dw picture,lake_picture,drive_picture,terrain_picture,split_picture,phase_picture,finale_picture
        include '../assets/sizes.asm'
        align 256
; ALIGN 256 davor richtet light_table auf eine volle Seite aus.
; light_table und sine_table belegen je 256 Bytes. Deshalb liegen auch
; moire_patterns und die folgenden ganzen Tabellen auf Seitengrenzen.
; LD H,Tabelle/256 plus LD L,Index ersetzt eine 16-Bit-Addition.
light_table:    incbin '../assets/light.bin'
sine_table:     incbin '../assets/sine.bin'
moire_patterns: incbin '../assets/moire.bin'
; Statische Geometrie- und Projektionstabellen; keine Videoframes.
; GEOMETRIEDATEN. Karte: 64*64 Hoehenbytes; Projektion/Farbe: je 16*64.
; X-Abtastung: 64 Spalten * 16 Tiefen = 1024 Bytes, signed Abstaende modulo 64.
; Farbtabelle und Projektion muessen exakt 1024 Bytes auseinanderliegen,
; weil terrain_sample allein D um 4 erhoeht. ASSERTs unten pruefen das.
terrain_map:    incbin '../assets/terrain-map.bin'
terrain_projection: incbin '../assets/terrain-projection.bin'
terrain_colours: incbin '../assets/terrain-colours.bin'
terrain_samples: incbin '../assets/terrain-samples.bin'
terrain_depths: incbin '../assets/terrain-depths.bin'
terrain_track:  incbin '../assets/terrain-track.bin'
; KOMPRIMIERTE SZENENDATEN. INCL48 ist eine Assemblerfunktion:
; RASM liest die Datei und legt ihren LZ48-Strom im Programm ab.
; LZ48_decrunch expandiert diesen Strom erst auf dem CPC. Die *.rle-Dateien
; des Grafikgenerators gehoeren nicht zu diesem Ladepfad.
; Sieben Motive entpacken jeweils nach #c000; road/water/scroll nach #0000.
picture:        incl48 '../assets/title.scr'
lake_picture:   incl48 '../assets/lake.scr'
drive_picture:  incl48 '../assets/drive.scr'
terrain_picture: incl48 '../assets/terrain.scr'
split_picture:  incl48 '../assets/split.scr'
phase_picture:  incl48 '../assets/phase.scr'
finale_picture: incl48 '../assets/finale.scr'
road_packed:    incl48 '../assets/road.bin'
water_packed:   incl48 '../assets/water.bin'
scroll_packed:  incl48 '../assets/scroll.bin'
; ENDE EXKLUSIV. Die Laenge ist program_end-start; hier folgt kein Datenbyte.
; Die ASSERTs brechen den Build ab, falls Code in die Adressliste reicht
; oder eine schnelle Tabellenadressierung ihre Ausrichtungsannahme verliert.
; SAVE erzeugt dieselben Nutzbytes als BIN sowie in CPC-Bandbloecken im CDT.
; RUN #4000 legt die Startadresse fuer das erzeugte Programm fest.
program_end:
        assert program_end < #b800
        assert (terrain_map & 255) == 0
        assert (terrain_projection & 255) == 0
        assert terrain_colours-terrain_projection == 1024
        assert terrain_samples-terrain_colours == 1024
        save '../build/phosphor464.bin',start,program_end-start
        save 'PHOSPHOR.BIN',start,program_end-start,TAPE,'../build/phosphor464.cdt'
