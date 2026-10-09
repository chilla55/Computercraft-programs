-- Mapping derived from the supplied four-burner position/gimbal probe.
return {
    -- Local +Y is up, +Z is right, and +X is forward on this craft.
    burners = {
        leftFront = "hot_air_burner_5",
        leftBack = "hot_air_burner_4",
        rightFront = "hot_air_burner_3",
        rightBack = "hot_air_burner_2",
    },
    gyro = {
        name = "gimbal_sensor_0",
        -- getAngles returns a two-element degree table on this installed sensor.
        -- Normalized convention: pitch > 0 nose UP; roll > 0 RIGHT side DOWN.
        -- Axis order/signs match geometry in the supplied tilted snapshot.
        read = function(device)
            local angles = device.getAngles()
            assert(type(angles) == "table" and type(angles[1]) == "number"
                and type(angles[2]) == "number", "Invalid gimbal getAngles result")
            return -angles[2], angles[1]
        end,
    },
    interval = 0.1,
    burnerStepsPerSecond = 2,
    -- Tuning pass 2: earlier braking for the delayed balloon response.
    -- Still requires in-game validation.
    pitch = { kp = 0.025, kd = 0.15 },
    -- Hands-off roll trial: brake rotation earlier to reduce persistent rocking.
    roll = { kp = 0.025, kd = 0.12 },
    derivativeFilterSeconds = 0.3,
    burnerPitchAuthority = 3, -- maximum signal difference from collective per corner
    burnerRollAuthority = 3,
    -- Retain the stronger differential from the powered-flight trial.
    -- Separate powered-flight trial: stronger angle correction, same rate damping.
    thrusterPitch = { kp = 0.075, kd = 0.15 },
    thrusterPitchAuthority = 0.70, -- feedback throttle reduction for leveling
    -- Trial: reduce lower forward thrust immediately, before the nose rises.
    thrusterPitchTrim = -0.30, -- additive throttle differential, not burner trim
    -- Front/back and left/right burner differences assume more signal gives more lift.
    -- Diagnostic only: disable hover trim to isolate its effect after W release.
    -- Validated hover baseline: front +0.25 each, back -0.25 each.
    burnerTrim = { leftFront = 0, leftBack = 0,
        rightFront = 0, rightBack = 0 },
}
