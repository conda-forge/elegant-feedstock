#!/bin/bash

set -xeuo pipefail

if [[ "$mpi" == "openmpi" ]]; then
  export OMPI_MCA_plm=isolated
  export OMPI_MCA_rmaps_base_oversubscribe=yes
  export OMPI_MCA_btl_vader_single_copy_mechanism=none
fi

which Pelegant

mpirun -np 1 Pelegant || echo "unable to run Pelegant :("
