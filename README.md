# IntLog
Interrupt logging for 16-bit DOS programs

IntLog allows for monitoring and logging BIOS and DOS interrupts.  IntLog will hook into the requested interrupt as a TSR, and then record all calls made to a tab-delimited file, noting the calling address, all register values, a particular followed memory location, and any strings pointed to by the DX register (useful for DOS functions).

Usage
--
```
paladin prepare -r1 
```
