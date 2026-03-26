# Makefile for ExVrp NIF compilation
#
# This Makefile is used by elixir_make to compile the C++ NIF.

# Erlang paths
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval "io:format(\"~ts/erts-~ts/include/\", [code:root_dir(), erlang:system_info(version)])." -s init stop)
ERL_INTERFACE_INCLUDE_DIR ?= $(shell erl -noshell -eval "io:format(\"~ts\", [code:lib_dir(erl_interface, include)])." -s init stop)
ERL_INTERFACE_LIB_DIR ?= $(shell erl -noshell -eval "io:format(\"~ts\", [code:lib_dir(erl_interface, lib)])." -s init stop)

# Platform detection
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
	LDFLAGS += -dynamiclib -undefined dynamic_lookup
	SO_EXT = so
else
	LDFLAGS += -shared
	SO_EXT = so
endif

# Compiler settings - use clang++ for sanitizers, otherwise default to g++
ifdef SANITIZE
CXX = clang++
else
CXX ?= g++
endif

# Base compiler flags
CXXFLAGS = -std=c++20 -Wall -Wextra -fPIC -fvisibility=hidden
CXXFLAGS += -I$(ERTS_INCLUDE_DIR)
CXXFLAGS += -Ic_src
CXXFLAGS += -Ic_src/pyvrp

# Sanitizer support (set SANITIZE=1 to enable)
# Use with: task test:asan
ifdef SANITIZE
# Debug build with sanitizers - no LTO, keep frame pointers
CXXFLAGS += -O1 -g -fno-omit-frame-pointer -fno-optimize-sibling-calls
CXXFLAGS += -fsanitize=address,undefined
CXXFLAGS += -fno-sanitize-recover=all
LDFLAGS += -fsanitize=address,undefined
# ASan requires shared runtime for NIFs
ifeq ($(UNAME_S),Linux)
LDFLAGS += -shared-libasan
endif
else
# Release build: optimized with LTO, disable assertions
CXXFLAGS += -O3 -flto -DNDEBUG
LDFLAGS += -flto
# Disable dangling-reference warning from PyVRP's Route.h (false positive in GCC 14)
# Only add for GCC, Clang doesn't have this warning
ifneq (,$(findstring g++,$(shell $(CXX) --version)))
CXXFLAGS += -Wno-dangling-reference
endif
endif

# Fine includes (use -isystem for angle-bracket includes like <fine.hpp>)
ifdef FINE_INCLUDE_DIR
CXXFLAGS += -isystem $(FINE_INCLUDE_DIR)
endif

# Output - use MIX_APP_PATH/priv when available (elixir_make sets this),
# fall back to local priv/ for standalone builds
ifdef MIX_APP_PATH
PRIV_DIR = $(MIX_APP_PATH)/priv
else
PRIV_DIR = priv
endif
NIF_SO = $(PRIV_DIR)/ex_vrp_nif.$(SO_EXT)

# Source files - NIF bindings
NIF_SRC = c_src/ex_vrp_nif.cpp

# PyVRP core sources (from latest main branch)
PYVRP_CORE_SRC = \
	c_src/pyvrp/Activity.cpp \
	c_src/pyvrp/CostEvaluator.cpp \
	c_src/pyvrp/DurationSegment.cpp \
	c_src/pyvrp/DynamicBitset.cpp \
	c_src/pyvrp/LoadSegment.cpp \
	c_src/pyvrp/ProblemData.cpp \
	c_src/pyvrp/RandomNumberGenerator.cpp \
	c_src/pyvrp/Route.cpp \
	c_src/pyvrp/Solution.cpp \
	c_src/pyvrp/Trip.cpp

# PyVRP search sources
PYVRP_SEARCH_SRC = \
	c_src/pyvrp/search/LocalSearch.cpp \
	c_src/pyvrp/search/neighbourhood.cpp \
	c_src/pyvrp/search/PerturbationManager.cpp \
	c_src/pyvrp/search/RelocateWithDepot.cpp \
	c_src/pyvrp/search/RemoveAdjacentDepot.cpp \
	c_src/pyvrp/search/RemoveOptional.cpp \
	c_src/pyvrp/search/ReplaceGroup.cpp \
	c_src/pyvrp/search/ReplaceOptional.cpp \
	c_src/pyvrp/search/Route.cpp \
	c_src/pyvrp/search/SearchSpace.cpp \
	c_src/pyvrp/search/Solution.cpp \
	c_src/pyvrp/search/SwapTails.cpp

ALL_SRC = $(NIF_SRC) $(PYVRP_CORE_SRC) $(PYVRP_SEARCH_SRC)

# Object files
OBJ_DIR = c_src/obj
OBJS = $(patsubst c_src/%.cpp,$(OBJ_DIR)/%.o,$(ALL_SRC))

# Toolchain fingerprint: force full rebuild when compiler or system libs change.
# Without this, a devenv/nix update can swap the compiler or glibc under us,
# leaving stale .o files that link against the wrong libraries and silently
# degrade NIF performance by ~2x.
TOOLCHAIN_ID := $(shell $(CXX) --version | head -1)$(shell $(CXX) -print-file-name=libc.so)
SHASUM := $(shell command -v shasum 2>/dev/null || command -v sha1sum 2>/dev/null || echo "md5sum")
TOOLCHAIN_HASH := $(shell echo "$(TOOLCHAIN_ID)" | $(SHASUM) | cut -c1-16)
TOOLCHAIN_STAMP = $(OBJ_DIR)/.toolchain_$(TOOLCHAIN_HASH)

all: $(PRIV_DIR) $(TOOLCHAIN_STAMP) $(NIF_SO)

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

$(TOOLCHAIN_STAMP):
	@rm -rf $(OBJ_DIR)
	@mkdir -p $(OBJ_DIR)/pyvrp/search
	@touch $@

# Object files depend on toolchain stamp via order-only prerequisite
# to prevent parallel make from compiling while the stamp rule cleans obj/
$(OBJ_DIR)/%.o: c_src/%.cpp | $(TOOLCHAIN_STAMP)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(NIF_SO): $(OBJS)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $^

clean:
	rm -rf $(PRIV_DIR)/*.$(SO_EXT)
	rm -rf $(OBJ_DIR)

.PHONY: all clean
