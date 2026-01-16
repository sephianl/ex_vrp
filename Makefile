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
	LDFLAGS += -flto -dynamiclib -undefined dynamic_lookup
	SO_EXT = so
else
	LDFLAGS += -flto -shared
	SO_EXT = so
endif

# Compiler settings
CXX ?= g++
# Match PyVRP's release build: disable assertions with NDEBUG
CXXFLAGS = -std=c++20 -O3 -flto -Wall -Wextra -fPIC -fvisibility=hidden -DNDEBUG
# Disable dangling-reference warning from PyVRP's Route.h (false positive in GCC 14)
CXXFLAGS += -Wno-dangling-reference
# Disable unused-parameter warnings - common in NIF code where env isn't always used
CXXFLAGS += -Wno-unused-parameter
CXXFLAGS += -I$(ERTS_INCLUDE_DIR)
CXXFLAGS += -Ic_src
CXXFLAGS += -Ic_src/pyvrp

# Fine includes
ifdef FINE_INCLUDE_DIR
CXXFLAGS += -I$(FINE_INCLUDE_DIR)
endif

# Output
PRIV_DIR = priv
NIF_SO = $(PRIV_DIR)/ex_vrp_nif.$(SO_EXT)

# Source files - NIF bindings
NIF_SRC = c_src/ex_vrp_nif.cpp

# PyVRP core sources (from latest main branch)
PYVRP_CORE_SRC = \
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
	c_src/pyvrp/search/PerturbationManager.cpp \
	c_src/pyvrp/search/RelocateWithDepot.cpp \
	c_src/pyvrp/search/Route.cpp \
	c_src/pyvrp/search/SearchSpace.cpp \
	c_src/pyvrp/search/Solution.cpp \
	c_src/pyvrp/search/SwapRoutes.cpp \
	c_src/pyvrp/search/SwapStar.cpp \
	c_src/pyvrp/search/SwapTails.cpp \
	c_src/pyvrp/search/primitives.cpp

ALL_SRC = $(NIF_SRC) $(PYVRP_CORE_SRC) $(PYVRP_SEARCH_SRC)

# Object files
OBJ_DIR = c_src/obj
OBJS = $(patsubst c_src/%.cpp,$(OBJ_DIR)/%.o,$(ALL_SRC))

all: $(PRIV_DIR) $(NIF_SO)

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

# Create all object directories
$(OBJ_DIR)/%.o: c_src/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(NIF_SO): $(OBJS)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $^

clean:
	rm -rf $(PRIV_DIR)/*.$(SO_EXT)
	rm -rf $(OBJ_DIR)

.PHONY: all clean
