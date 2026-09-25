# ComputerCraft power-plant programs

The new [distributed transformer system](Powerplant/distributed/README.md) separates the UI/configuration master, variac regulation and protection/breaker control across three computers. All can trip; only protection can close breakers. It includes ender-modem communication and verified, staged GitHub updates.

The previous standalone regulator is backed up on [`backup/standalone-regulator-v18`](https://github.com/chilla55/Computercraft-programs/tree/backup/standalone-regulator-v18), commit `929f894`. Its [setup guide](Powerplant/regulator/SETUP.md) and the existing [plant-wide controller](Powerplant/controller/SETUP.md) remain available for reference and regression tests.

The distributed version has mock integration tests and still needs commissioning in Minecraft. Start with all input/output breakers open and the old regulator stopped; follow the distributed setup guide before enabling it.
