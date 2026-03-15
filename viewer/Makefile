# pmux-viewer — compiled as x86_64 (Parsec SDK is x86_64 only)

CC      = clang
ARCH    = -arch x86_64
CFLAGS  = -Wall -Wextra -O2 $(ARCH) -I. -F.
LDFLAGS = $(ARCH) -F. -rpath @executable_path

# SDL2.framework (universal) + Parsec SDK (x86_64) + system frameworks
FRAMEWORKS = -framework SDL2 \
             -framework OpenGL -framework VideoToolbox -framework CoreMedia \
             -framework CoreAudio -framework AudioToolbox -framework IOKit \
             -framework Carbon -framework AppKit -framework Metal \
             -framework QuartzCore -framework CoreGraphics -framework CoreFoundation \
             -framework Security -framework IOSurface -framework CoreVideo \
             -framework CoreText

TARGET = pmux-viewer

all: $(TARGET)

$(TARGET): viewer.c sdk/parsec-dso.h sdk/parsec.h
	$(CC) $(CFLAGS) -o $@ viewer.c $(LDFLAGS) $(FRAMEWORKS)
	@echo "Built $(TARGET) (x86_64 — runs via Rosetta 2)"

clean:
	rm -f $(TARGET)

.PHONY: all clean
