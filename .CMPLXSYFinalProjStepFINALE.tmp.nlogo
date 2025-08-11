;; temp_scale (in spread/ignite): try 200 – 600. LOWER temp_scale makes small intensities more effective; HIGHER temp_scale requires stronger flames to spread.
;; growth-rate (in update-burning-trees): 0.01 – 0.03. Lower → slower growth, easier to extinguish.
;; max_temp / color-max (carrying capacity): 1000 – 3000. Larger values raise the ceiling of fire-intensity.
;; extinguish-rate (slider): increase if firefighters are still losing. Start testing around 20 – 60 (units/tick) depending on map scale and firefighter counts.
;; Weights in ignition/spread (0.65/0.35 and 0.70/0.30): change them if you want humidity to matter more (increase humidity weight) or temperature to dominate more (increase temp weight).
extensions [csv] 

globals [
  initial-trees
  burned-trees
  extinguished-trees
  net-extinguish-rate
  relative-humidity
  ambient-temp
]

patches-own [
  tree-state
  burn-counter
  fire-intensity
  max-burn-counter
]

breed [firefighters firefighter]

firefighters-own [
  squad-id
  is-leader?
  mode

  ;; NEW:
  target       ;; will hold a patch agent (or nobody)
  working?     ;; boolean: true when standing on target and actively extinguishing
  move-speed   ;; how far the firefighter moves per tick
]

to setup
  clear-all
  set-default-shape turtles "square"
  set ambient-temp average-air-temperature

  ;; Use initial slider value for runtime RH
  set relative-humidity initial-relative-humidity

  ;; Extinguish-rate scales with humidity
  let clamped-rh max list 1 (min list 100 relative-humidity)
  set net-extinguish-rate 60 * ((clamped-rh) / 100)

  ;; Make some green trees
  load-fixed-map

  ;; Random ignition point
  let ignition-patch one-of patches with [tree-state = "unaffected"]
  if ignition-patch != nobody [
    ask ignition-patch [
      start-fire
      ask neighbors4 with [tree-state = "unaffected"] [
        ignite
      ]
    ]
  ]

  ;; Set tree counts
  set initial-trees count patches with [pcolor = green]
  set burned-trees 0
  set extinguished-trees

  ;; Deploy firefighters
  let squad-size 5
  let num-squads floor (num-firefighters / squad-size)
  let spacing 3
  let start-y min-pycor + 5

  let sid 0
  repeat num-squads [
    let base-x (min-pxcor + 2 + random 3) + (sid * 5)
    let base-y (start-y + random spacing)

    create-firefighters squad-size [
      set shape "person"
      set color blue
      set size 7
      setxy base-x base-y
      set squad-id sid
      set is-leader? false
      set mode "group"

      ;; NEW initialisation:
      set target nobody
      set working? false
      set move-speed 0.8  ;; adjust to taste (0.5–1.0 is usually good)
    ]

    ask one-of firefighters with [squad-id = sid and is-leader? = false] [
      set color cyan
      set is-leader? true
    ]

    set sid sid + 1
  ]

  reset-ticks
end

to load-fixed-map
   file-open "fixed-forest.csv"
   let _header file-read-line
    while [not file-at-end?] [
     let line file-read-line
     let parts csv:from-row line  ;; already typed as numbers/strings
     let x item 0 parts          ;; already a number
     let y item 1 parts          ;; already a number
     let state item 2 parts      ;; string
     let burn item 3 parts       ;; number
     let intensity item 4 parts  ;; number
     let maxburn item 5 parts    ;; number
      ask patch x y [
       set tree-state state
       set burn-counter burn
       set fire-intensity intensity
       set max-burn-counter maxburn

       if state = "unaffected" [ set pcolor green ]
       if state = "empty"       [ set pcolor brown ]
       if state = "burning"     [ set pcolor orange ]
       if state = "burnt"       [ set pcolor black ]
       if state = "extinguished"[ set pcolor gray ]
        ]
   ]
   file-close end 

to go
  if not any? patches with [tree-state = "burning"] [

    stop
  ]

  ;; Wind Speed
  let wind-x (east-wind-speed - west-wind-speed)   ;; positive → wind blows east
  let wind-y (north-wind-speed - south-wind-speed) ;; positive → wind blows north
  let wind-mag sqrt (wind-x ^ 2 + wind-y ^ 2)

  ;; Spread fire (single attempt per unaffected patch; uses neighbor max intensity + adjacency)
  ask patches with [tree-state = "unaffected"] [
    let burning-neighbors neighbors4 with [tree-state = "burning"]
    if any? burning-neighbors [
      ;; environment
      let clamped-rh max list 1 (min list 100 relative-humidity)
      let min_humidity 0.02
      let rh_midpoint 50
      let rh_steepness 0.06
      let humidity_factor min_humidity + (1 - min_humidity) / (1 + exp (rh_steepness * (clamped-rh - rh_midpoint)))

      ;; neighbor stats
      let max_neighbor (max [fire-intensity] of burning-neighbors) + ambient-temp
      let n_burn count burning-neighbors

      ;; adjacency factor: more burning neighbours raises chance but saturates
      let neighbor_scale 2     ;; 1-> weak, 2-> near-full adjacency effect
      let adjacency_factor min list 1 (n_burn / neighbor_scale)

      ;; temperature response (tunable)
      let temp_scale 100       ;; TUNE: larger -> need stronger fire to spread
      let temp_factor 0
      if max_neighbor > 0 [
        set temp_factor (max_neighbor / (max_neighbor + temp_scale)) * adjacency_factor
      ]

      ;; combine (temp dominates, humidity still matters)
      let base_spread_factor 0.5 * (0.70 * temp_factor + 0.30 * humidity_factor)

      ; wind influence
      let wind_factor 1
      if wind-mag > 0 [
        if any? burning-neighbors [
          let influence 0
          foreach sort burning-neighbors [
            bn ->
            ;; vector from burning neighbor to this candidate patch
            let windDX (pxcor - [pxcor] of bn)
            let windDY (pycor - [pycor] of bn)
            let dir-dot (windDX * wind-x + windDY * wind-y)
            let dir-mag sqrt (windDX ^ 2 + windDY ^ 2)
            if dir-mag > 0 [
              let cos-angle dir-dot / (dir-mag * wind-mag)
              ;; clamp numerical drift
              if cos-angle > 1 [ set cos-angle 1 ]
              if cos-angle < -1 [ set cos-angle -1 ]
              ;; cos-angle ≈ 1 => downwind (boost), ≈ -1 => upwind (penalty)
              set influence influence + (1 + 0.5 * cos-angle)
            ]
          ]
          ;; average influence from burning neighbors
          set wind_factor influence / count burning-neighbors
        ]
      ]

      let spread_factor base_spread_factor * wind_factor

      ;; global limiter to slow down unrealistically fast spread
      let spread_multiplier 0.6   ;; TUNE between 0.3 - 1.0 (lower -> slower overall spread)
      set spread_factor spread_factor * spread_multiplier

      if spread_factor > 1 [ set spread_factor 1 ]
      if spread_factor < 0 [ set spread_factor 0 ]
      if random-float 1 < spread_factor [
        ;; ignite deterministically — ignite() now seeds intensity (see ignite below)
        ignite
      ]
    ]
  ]

  ;; Decrease humidity based on burn coverage
  let burning-patches count patches with [tree-state = "burning"]
  let total-patches count patches
  let burn-fraction burning-patches / total-patches
  set relative-humidity max list 1 (relative-humidity - (1.25 * burn-fraction))

  update-burning-trees
  update-firefighters
  tick
end

to start-fire  ;; patch procedure
  set tree-state "burning"
  set fire-intensity initial-fire-intensity + ambient-temp
  set burn-counter 0

  let clamped-rh max list 1 (min list 100 relative-humidity)
  let humidity-burn-factor (1.2 - (clamped-rh / 100) * 0.5) ;; Smaller RH Effect
  set max-burn-counter round ((720 + random 720) * humidity-burn-factor) ;; Burns 12 Hours to 1 Day

  set pcolor orange
  set burned-trees burned-trees + 1
end


to ignite  ;; patch procedure — deterministic: called when we decide to ignite
  ;; environmental RH used for burn-duration scaling (left similar to before)
  let clamped-rh max list 1 (min list 100 relative-humidity)
  let humidity-burn-factor (1.2 - (clamped-rh / 100) * 0.5)

  ;; determine seed intensity from neighbors (start weaker than source)
  let burning-neighbors neighbors4 with [tree-state = "burning"]
  let neighbor_intensity 0
  if any? burning-neighbors [
    set neighbor_intensity max [fire-intensity] of burning-neighbors
  ]

  ;; seed scaling: new fires start as a fraction of the neighbor intensity
  let seed_scale 0.875      ;; TUNE: lower -> newly ignited patches start weaker)
  let seed_min 5           ;; minimal starting intensity
  let seed_intensity seed_min
  ifelse neighbor_intensity > 0 [
    set seed_intensity max list seed_min ((neighbor_intensity * seed_scale) + ambient-temp)
  ] [
    set seed_intensity max list seed_min ((initial-fire-intensity * seed_scale) + ambient-temp)
  ]

  ;; ignite deterministically
  set tree-state "burning"
  set fire-intensity seed_intensity
  set burn-counter 0

  ;; make burn duration scale modestly with RH AND with seed intensity
  let intensity_ratio seed_intensity / max list 1 initial-fire-intensity
  set max-burn-counter round ((720 + random 720) * humidity-burn-factor * (0.5 + 0.5 * intensity_ratio))

  set pcolor orange
  set burned-trees burned-trees + 1
end


to update-burning-trees
  ask patches with [tree-state = "burning"] [
    set burn-counter burn-counter + 1

    let growth-rate 0.05
    let max_temp 1000

    if fire-intensity <= 0 [ set fire-intensity 1 ]

    let dI growth-rate * fire-intensity * (1 - fire-intensity / max_temp)
    set fire-intensity fire-intensity + dI + (ambient-temp * 0.01)  ;; small constant push from air temp

    if fire-intensity > max_temp [ set fire-intensity max_temp ]
    if fire-intensity < 0 [ set fire-intensity 0 ]

    ;; ---- Color Mapping ----
    let color-min-intensity 1
    let color-max-intensity max_temp
    let base-color scale-color orange fire-intensity color-min-intensity color-max-intensity

    ;; Ensure low-intensity flames look deep orange, not black
    if fire-intensity <= 50 [
      set base-color orange + 100
    ]

    set pcolor base-color

    ;; ---- Burnout ----
    if burn-counter >= max-burn-counter [
      set tree-state "burnt"
      set pcolor black
    ]
  ]
end

to update-firefighters
  ;; update net extinguish rate based on current RH
  let clamped-rh max list 1 (min list 100 relative-humidity)
  set net-extinguish-rate 60 * ((clamped-rh) / 100) ;; Firefighters are using high-pressure hoses

  ;; tuning params
  let leader_switch_threshold 2.0   ;; leader will switch target if a frontier is this much closer
  let switch_threshold 1.0          ;; follower switching threshold
  let color_max 1000                ;; should match update-burning-trees' max_temp
  ;; move & arrival
  ;; LEADERS
  ask firefighters with [is-leader?] [
    ;; target nearest frontier patch if any
    let frontier patches with [tree-state = "burning" and any? neighbors4 with [tree-state = "unaffected"]]
    ifelse any? frontier [
      let best_frontier min-one-of frontier [distance myself]
      ifelse target = nobody [
        set target best_frontier
        set working? false
      ] [
        ;; if current target stopped burning -> switch
        ifelse [tree-state] of target != "burning" [
          set target best_frontier
          set working? false
        ] [
          ;; if a frontier is *significantly* closer than current target, switch
          if distance best_frontier + leader_switch_threshold < distance target [
            set target best_frontier
            set working? false
          ]
        ]
      ]
    ] [
      ;; fallback: nearest burning patch
      if target = nobody or (target != nobody and [tree-state] of target != "burning") [
        set target min-one-of patches with [tree-state = "burning"] [distance myself]
        set working? false
      ]
    ]

    ;; move / work
    if target != nobody [
      ifelse patch-here = target [
        set working? true
      ] [
        if not working? [
          face target
          fd move-speed
        ]
      ]
    ]

    ;; extinguish if working
    if working? [
      ask patch-here [
        if tree-state = "burning" [
          set fire-intensity fire-intensity - net-extinguish-rate
          set pcolor scale-color blue fire-intensity 0 color_max
          if fire-intensity <= 0 [
            set tree-state "extinguished"
            set pcolor gray
            set extinguished-trees extinguished-trees + 1
          ]
        ]
      ]
      ;; if patch no longer burning, clear target
      if [tree-state] of patch-here != "burning" [
        set target nobody
        set working? false
      ]
    ]
  ]

  ;; FOLLOWERS
  ask firefighters with [not is-leader?] [
    let leader one-of firefighters with [squad-id = [squad-id] of myself and is-leader?]

    if mode = "group" [
      ;; follow leader's target if it exists and is burning
      ifelse leader != nobody and [target] of leader != nobody and [tree-state] of [target] of leader = "burning" [
        if target != [target] of leader [
          set target [target] of leader
          set working? false
        ]
      ] [
        ;; fallback to nearest frontier, else nearest burning patch
        let frontier patches with [tree-state = "burning" and any? neighbors4 with [tree-state = "unaffected"]]
        ifelse any? frontier [
          if target = nobody or (target != nobody and [tree-state] of target != "burning") [
            set target min-one-of frontier [distance myself]
            set working? false
          ]
        ] [
          if target = nobody or (target != nobody and [tree-state] of target != "burning") [
            set target min-one-of patches with [tree-state = "burning"] [distance myself]
            set working? false
          ]
        ]
      ]
    ]

    if mode = "solo" [
      if target = nobody or (target != nobody and [tree-state] of target != "burning") [
        set target min-one-of patches with [tree-state = "burning"] [distance myself]
        set working? false
      ]
    ]

    ;; allow switching to solo if significantly closer to a frontier than leader
    if mode = "group" and leader != nobody [
      let nearest_frontier min-one-of patches with [tree-state = "burning" and any? neighbors4 with [tree-state = "unaffected"]] [distance myself]
      if nearest_frontier != nobody [
        if distance nearest_frontier < (distance leader - switch_threshold) [
          set mode "solo"
          set target nearest_frontier
          set working? false
        ]
      ]
    ]

    ;; move / work
    if target != nobody [
      ifelse patch-here = target [
        set working? true
      ] [
        if not working? [
          face target
          fd move-speed
        ]
      ]
    ]

    ;; extinguish if working
    if working? [
      ask patch-here [
        if tree-state = "burning" [
          set fire-intensity fire-intensity - net-extinguish-rate
          set pcolor scale-color blue fire-intensity 0 color_max
          if fire-intensity <= 0 [
            set tree-state "extinguished"
            set pcolor gray
          ]
        ]
      ]
      if [tree-state] of patch-here != "burning" [
        set target nobody
        set working? false
        set mode "group"
      ]
    ]
  ]
end

to write-run-summary
  let pct_saved 100 * (initial-trees - count patches with [tree-state = "burnt"]) / initial-trees

  ;; Example: print to console or write to file
  show (word "Initial trees: " initial-trees)
  show (word "Burned trees: " burned-trees)
  show (word "Extinguished trees: " extinguished-trees)
  show (word "Burnt trees: " count patches with [tree-state = "burnt"])
  show (word "Percent area saved: " pct_saved "%")
  show (word "Run length (ticks): " ticks)

  ;; Or write to CSV file here if you want to save multiple runs
end
@#$#@#$#@
GRAPHICS-WINDOW
200
10
710
521
-1
-1
2.0
1
10
1
1
1
0
0
0
1
-125
125
-125
125
1
1
1
ticks
30.0

MONITOR
719
11
834
56
percent burning
(burned-trees / initial-trees)\n* 100
1
1
11

SLIDER
6
92
191
125
density
density
0.0
99.0
65.0
1.0
1
%
HORIZONTAL

BUTTON
102
36
171
72
go
go
T
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
22
36
92
72
setup
setup
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

SLIDER
13
132
185
165
num-firefighters
num-firefighters
1
50
20.0
1
1
NIL
HORIZONTAL

SLIDER
11
211
183
244
initial-relative-humidity
initial-relative-humidity
0
100
64.97
0.01
1
NIL
HORIZONTAL

SLIDER
10
170
182
203
initial-fire-intensity
initial-fire-intensity
250
1000
1000.0
1
1
NIL
HORIZONTAL

MONITOR
719
66
825
111
NIL
relative-humidity
17
1
11

SLIDER
13
289
185
322
north-wind-speed
north-wind-speed
0
25
25.0
1
1
NIL
HORIZONTAL

SLIDER
13
327
185
360
south-wind-speed
south-wind-speed
0
25
0.0
1
1
NIL
HORIZONTAL

SLIDER
12
367
184
400
west-wind-speed
west-wind-speed
0
25
25.0
1
1
NIL
HORIZONTAL

SLIDER
13
406
185
439
east-wind-speed
east-wind-speed
0
25
0.0
1
1
NIL
HORIZONTAL

SLIDER
6
250
186
283
average-air-temperature
average-air-temperature
10
50
40.0
1
1
NIL
HORIZONTAL

@#$#@#$#@
## WHAT IS IT?

This project simulates the spread of a fire through a forest.  It shows that the fire's chance of reaching the right edge of the forest depends critically on the density of trees. This is an example of a common feature of complex systems, the presence of a non-linear threshold or critical parameter.

## HOW IT WORKS

The fire starts on the left edge of the forest, and spreads to neighboring trees. The fire spreads in four directions: north, east, south, and west.

The model assumes there is no wind.  So, the fire must have trees along its path in order to advance.  That is, the fire cannot skip over an unwooded area (patch), so such a patch blocks the fire's motion in that direction.

## HOW TO USE IT

Click the SETUP button to set up the trees (green) and fire (red on the left-hand side).

Click the GO button to start the simulation.

The DENSITY slider controls the density of trees in the forest. (Note: Changes in the DENSITY slider do not take effect until the next SETUP.)

## THINGS TO NOTICE

When you run the model, how much of the forest burns. If you run it again with the same settings, do the same trees burn? How similar is the burn from run to run?

Each turtle that represents a piece of the fire is born and then dies without ever moving. If the fire is made of turtles but no turtles are moving, what does it mean to say that the fire moves? This is an example of different levels in a system: at the level of the individual turtles, there is no motion, but at the level of the turtles collectively over time, the fire moves.

## THINGS TO TRY

Set the density of trees to 55%. At this setting, there is virtually no chance that the fire will reach the right edge of the forest. Set the density of trees to 70%. At this setting, it is almost certain that the fire will reach the right edge. There is a sharp transition around 59% density. At 59% density, the fire has a 50/50 chance of reaching the right edge.

Try setting up and running a BehaviorSpace experiment (see Tools menu) to analyze the percent burned at different tree density levels. Plot the burn-percentage against the density. What kind of curve do you get?

Try changing the size of the lattice (`max-pxcor` and `max-pycor` in the Model Settings). Does it change the burn behavior of the fire?

## EXTENDING THE MODEL

What if the fire could spread in eight directions (including diagonals)? To do that, use `neighbors` instead of `neighbors4`. How would that change the fire's chances of reaching the right edge? In this model, what "critical density" of trees is needed for the fire to propagate?

Add wind to the model so that the fire can "jump" greater distances in certain directions.

Add the ability to plant trees where you want them. What configurations of trees allow the fire to cross the forest? Which don't? Why is over 59% density likely to result in a tree configuration that works? Why does the likelihood of such a configuration increase so rapidly at the 59% density?

The physicist Per Bak asked why we frequently see systems undergoing critical changes. He answers this by proposing the concept of [self-organzing criticality] (https://en.wikipedia.org/wiki/Self-organized_criticality) (SOC). Can you create a version of the fire model that exhibits SOC?

## NETLOGO FEATURES

Unburned trees are represented by green patches; burning trees are represented by turtles.  Two breeds of turtles are used, "fires" and "embers".  When a tree catches fire, a new fire turtle is created; a fire turns into an ember on the next turn.  Notice how the program gradually darkens the color of embers to achieve the visual effect of burning out.

The `neighbors4` primitive is used to spread the fire.

You could also write the model without turtles by just having the patches spread the fire, and doing it that way makes the code a little simpler.   Written that way, the model would run much slower, since all of the patches would always be active.  By using turtles, it's much easier to restrict the model's activity to just the area around the leading edge of the fire.

See the "CA 1D Rule 30" and "CA 1D Rule 30 Turtle" for an example of a model written both with and without turtles.

## RELATED MODELS

* Percolation
* Rumor Mill

## CREDITS AND REFERENCES

https://en.wikipedia.org/wiki/Forest-fire_model

## HOW TO CITE

If you mention this model or the NetLogo software in a publication, we ask that you include the citations below.

For the model itself:

* Wilensky, U. (1997).  NetLogo Fire model.  http://ccl.northwestern.edu/netlogo/models/Fire.  Center for Connected Learning and Computer-Based Modeling, Northwestern University, Evanston, IL.

Please cite the NetLogo software as:

* Wilensky, U. (1999). NetLogo. http://ccl.northwestern.edu/netlogo/. Center for Connected Learning and Computer-Based Modeling, Northwestern University, Evanston, IL.

## COPYRIGHT AND LICENSE

Copyright 1997 Uri Wilensky.

![CC BY-NC-SA 3.0](http://ccl.northwestern.edu/images/creativecommons/byncsa.png)

This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 3.0 License.  To view a copy of this license, visit https://creativecommons.org/licenses/by-nc-sa/3.0/ or send a letter to Creative Commons, 559 Nathan Abbott Way, Stanford, California 94305, USA.

Commercial licenses are also available. To inquire about commercial licenses, please contact Uri Wilensky at uri@northwestern.edu.

This model was created as part of the project: CONNECTED MATHEMATICS: MAKING SENSE OF COMPLEX PHENOMENA THROUGH BUILDING OBJECT-BASED PARALLEL MODELS (OBPML).  The project gratefully acknowledges the support of the National Science Foundation (Applications of Advanced Technologies Program) -- grant numbers RED #9552950 and REC #9632612.

This model was developed at the MIT Media Lab using CM StarLogo.  See Resnick, M. (1994) "Turtles, Termites and Traffic Jams: Explorations in Massively Parallel Microworlds."  Cambridge, MA: MIT Press.  Adapted to StarLogoT, 1997, as part of the Connected Mathematics Project.

This model was converted to NetLogo as part of the projects: PARTICIPATORY SIMULATIONS: NETWORK-BASED DESIGN FOR SYSTEMS LEARNING IN CLASSROOMS and/or INTEGRATED SIMULATION AND MODELING ENVIRONMENT. The project gratefully acknowledges the support of the National Science Foundation (REPP & ROLE programs) -- grant numbers REC #9814682 and REC-0126227. Converted from StarLogoT to NetLogo, 2001.

<!-- 1997 2001 MIT -->
@#$#@#$#@
default
true
0
Polygon -7500403 true true 150 5 40 250 150 205 260 250

airplane
true
0
Polygon -7500403 true true 150 0 135 15 120 60 120 105 15 165 15 195 120 180 135 240 105 270 120 285 150 270 180 285 210 270 165 240 180 180 285 195 285 165 180 105 180 60 165 15

arrow
true
0
Polygon -7500403 true true 150 0 0 150 105 150 105 293 195 293 195 150 300 150

box
false
0
Polygon -7500403 true true 150 285 285 225 285 75 150 135
Polygon -7500403 true true 150 135 15 75 150 15 285 75
Polygon -7500403 true true 15 75 15 225 150 285 150 135
Line -16777216 false 150 285 150 135
Line -16777216 false 150 135 15 75
Line -16777216 false 150 135 285 75

bug
true
0
Circle -7500403 true true 96 182 108
Circle -7500403 true true 110 127 80
Circle -7500403 true true 110 75 80
Line -7500403 true 150 100 80 30
Line -7500403 true 150 100 220 30

butterfly
true
0
Polygon -7500403 true true 150 165 209 199 225 225 225 255 195 270 165 255 150 240
Polygon -7500403 true true 150 165 89 198 75 225 75 255 105 270 135 255 150 240
Polygon -7500403 true true 139 148 100 105 55 90 25 90 10 105 10 135 25 180 40 195 85 194 139 163
Polygon -7500403 true true 162 150 200 105 245 90 275 90 290 105 290 135 275 180 260 195 215 195 162 165
Polygon -16777216 true false 150 255 135 225 120 150 135 120 150 105 165 120 180 150 165 225
Circle -16777216 true false 135 90 30
Line -16777216 false 150 105 195 60
Line -16777216 false 150 105 105 60

car
false
0
Polygon -7500403 true true 300 180 279 164 261 144 240 135 226 132 213 106 203 84 185 63 159 50 135 50 75 60 0 150 0 165 0 225 300 225 300 180
Circle -16777216 true false 180 180 90
Circle -16777216 true false 30 180 90
Polygon -16777216 true false 162 80 132 78 134 135 209 135 194 105 189 96 180 89
Circle -7500403 true true 47 195 58
Circle -7500403 true true 195 195 58

circle
false
0
Circle -7500403 true true 0 0 300

circle 2
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240

cow
false
0
Polygon -7500403 true true 200 193 197 249 179 249 177 196 166 187 140 189 93 191 78 179 72 211 49 209 48 181 37 149 25 120 25 89 45 72 103 84 179 75 198 76 252 64 272 81 293 103 285 121 255 121 242 118 224 167
Polygon -7500403 true true 73 210 86 251 62 249 48 208
Polygon -7500403 true true 25 114 16 195 9 204 23 213 25 200 39 123

cylinder
false
0
Circle -7500403 true true 0 0 300

dot
false
0
Circle -7500403 true true 90 90 120

face happy
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 255 90 239 62 213 47 191 67 179 90 203 109 218 150 225 192 218 210 203 227 181 251 194 236 217 212 240

face neutral
false
0
Circle -7500403 true true 8 7 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Rectangle -16777216 true false 60 195 240 225

face sad
false
0
Circle -7500403 true true 8 8 285
Circle -16777216 true false 60 75 60
Circle -16777216 true false 180 75 60
Polygon -16777216 true false 150 168 90 184 62 210 47 232 67 244 90 220 109 205 150 198 192 205 210 220 227 242 251 229 236 206 212 183

fish
false
0
Polygon -1 true false 44 131 21 87 15 86 0 120 15 150 0 180 13 214 20 212 45 166
Polygon -1 true false 135 195 119 235 95 218 76 210 46 204 60 165
Polygon -1 true false 75 45 83 77 71 103 86 114 166 78 135 60
Polygon -7500403 true true 30 136 151 77 226 81 280 119 292 146 292 160 287 170 270 195 195 210 151 212 30 166
Circle -16777216 true false 215 106 30

flag
false
0
Rectangle -7500403 true true 60 15 75 300
Polygon -7500403 true true 90 150 270 90 90 30
Line -7500403 true 75 135 90 135
Line -7500403 true 75 45 90 45

flower
false
0
Polygon -10899396 true false 135 120 165 165 180 210 180 240 150 300 165 300 195 240 195 195 165 135
Circle -7500403 true true 85 132 38
Circle -7500403 true true 130 147 38
Circle -7500403 true true 192 85 38
Circle -7500403 true true 85 40 38
Circle -7500403 true true 177 40 38
Circle -7500403 true true 177 132 38
Circle -7500403 true true 70 85 38
Circle -7500403 true true 130 25 38
Circle -7500403 true true 96 51 108
Circle -16777216 true false 113 68 74
Polygon -10899396 true false 189 233 219 188 249 173 279 188 234 218
Polygon -10899396 true false 180 255 150 210 105 210 75 240 135 240

house
false
0
Rectangle -7500403 true true 45 120 255 285
Rectangle -16777216 true false 120 210 180 285
Polygon -7500403 true true 15 120 150 15 285 120
Line -16777216 false 30 120 270 120

leaf
false
0
Polygon -7500403 true true 150 210 135 195 120 210 60 210 30 195 60 180 60 165 15 135 30 120 15 105 40 104 45 90 60 90 90 105 105 120 120 120 105 60 120 60 135 30 150 15 165 30 180 60 195 60 180 120 195 120 210 105 240 90 255 90 263 104 285 105 270 120 285 135 240 165 240 180 270 195 240 210 180 210 165 195
Polygon -7500403 true true 135 195 135 240 120 255 105 255 105 285 135 285 165 240 165 195

line
true
0
Line -7500403 true 150 0 150 300

line half
true
0
Line -7500403 true 150 0 150 150

pentagon
false
0
Polygon -7500403 true true 150 15 15 120 60 285 240 285 285 120

person
false
0
Circle -7500403 true true 110 5 80
Polygon -7500403 true true 105 90 120 195 90 285 105 300 135 300 150 225 165 300 195 300 210 285 180 195 195 90
Rectangle -7500403 true true 127 79 172 94
Polygon -7500403 true true 195 90 240 150 225 180 165 105
Polygon -7500403 true true 105 90 60 150 75 180 135 105

plant
false
0
Rectangle -7500403 true true 135 90 165 300
Polygon -7500403 true true 135 255 90 210 45 195 75 255 135 285
Polygon -7500403 true true 165 255 210 210 255 195 225 255 165 285
Polygon -7500403 true true 135 180 90 135 45 120 75 180 135 210
Polygon -7500403 true true 165 180 165 210 225 180 255 120 210 135
Polygon -7500403 true true 135 105 90 60 45 45 75 105 135 135
Polygon -7500403 true true 165 105 165 135 225 105 255 45 210 60
Polygon -7500403 true true 135 90 120 45 150 15 180 45 165 90

square
false
0
Rectangle -7500403 true true 30 30 270 270

square 2
false
0
Rectangle -7500403 true true 30 30 270 270
Rectangle -16777216 true false 60 60 240 240

star
false
0
Polygon -7500403 true true 151 1 185 108 298 108 207 175 242 282 151 216 59 282 94 175 3 108 116 108

target
false
0
Circle -7500403 true true 0 0 300
Circle -16777216 true false 30 30 240
Circle -7500403 true true 60 60 180
Circle -16777216 true false 90 90 120
Circle -7500403 true true 120 120 60

tree
false
0
Circle -7500403 true true 118 3 94
Rectangle -6459832 true false 120 195 180 300
Circle -7500403 true true 65 21 108
Circle -7500403 true true 116 41 127
Circle -7500403 true true 45 90 120
Circle -7500403 true true 104 74 152

triangle
false
0
Polygon -7500403 true true 150 30 15 255 285 255

triangle 2
false
0
Polygon -7500403 true true 150 30 15 255 285 255
Polygon -16777216 true false 151 99 225 223 75 224

truck
false
0
Rectangle -7500403 true true 4 45 195 187
Polygon -7500403 true true 296 193 296 150 259 134 244 104 208 104 207 194
Rectangle -1 true false 195 60 195 105
Polygon -16777216 true false 238 112 252 141 219 141 218 112
Circle -16777216 true false 234 174 42
Rectangle -7500403 true true 181 185 214 194
Circle -16777216 true false 144 174 42
Circle -16777216 true false 24 174 42
Circle -7500403 false true 24 174 42
Circle -7500403 false true 144 174 42
Circle -7500403 false true 234 174 42

turtle
true
0
Polygon -10899396 true false 215 204 240 233 246 254 228 266 215 252 193 210
Polygon -10899396 true false 195 90 225 75 245 75 260 89 269 108 261 124 240 105 225 105 210 105
Polygon -10899396 true false 105 90 75 75 55 75 40 89 31 108 39 124 60 105 75 105 90 105
Polygon -10899396 true false 132 85 134 64 107 51 108 17 150 2 192 18 192 52 169 65 172 87
Polygon -10899396 true false 85 204 60 233 54 254 72 266 85 252 107 210
Polygon -7500403 true true 119 75 179 75 209 101 224 135 220 225 175 261 128 261 81 224 74 135 88 99

wheel
false
0
Circle -7500403 true true 3 3 294
Circle -16777216 true false 30 30 240
Line -7500403 true 150 285 150 15
Line -7500403 true 15 150 285 150
Circle -7500403 true true 120 120 60
Line -7500403 true 216 40 79 269
Line -7500403 true 40 84 269 221
Line -7500403 true 40 216 269 79
Line -7500403 true 84 40 221 269

x
false
0
Polygon -7500403 true true 270 75 225 30 30 225 75 270
Polygon -7500403 true true 30 75 75 30 270 225 225 270
@#$#@#$#@
NetLogo 6.4.0
@#$#@#$#@
set density 60.0
setup
repeat 180 [ go ]
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
default
0.0
-0.2 0 0.0 1.0
0.0 1 1.0 0.0
0.2 0 0.0 1.0
link direction
true
0
Line -7500403 true 150 150 90 180
Line -7500403 true 150 150 210 180
@#$#@#$#@
0
@#$#@#$#@
