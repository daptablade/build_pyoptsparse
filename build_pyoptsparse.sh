#!/usr/bin/env bash
# Finds/downloads and unpacks pyOptSparse, IPOPT, and deps source
# archives to current directory. Chdirs to each directory in turn
# to build and install each package (except for pyOptSparse if
# build is disabled by command line options).
#
# Default values:
# IPOPT 3.12.x has a broken configure on Mac
IPOPT_VER=3.13.1
HSL_VER=2014.01.17
PREFIX=$HOME/ipopt
LINEAR_SOLVER=MUMPS
BUILD_PYOPTSPARSE=1
PYOPTSPARSE_BRANCH=v2.1.3
COMPILER_SUITE=GNU
INCLUDE_SNOPT=0
SNOPT_DIR=SNOPT
INCLUDE_PAROPT=0
BUILD_TIME=`date +%s`

set -x
ssh openmdao@web543.webfaction.com ls /home/openmdao/snopt_source
ssh openmdao@web543.webfaction.com ls /home/openmdao/snopt_source/snopt77

usage() {
cat <<USAGE
Download, configure, build, and install pyOptSparse with IPOPT
support and dependencies.

Usage:
$0 [-b branch] [-h] [-l linear_solver] [-n] [-p prefix] [-s snopt_dir]
    -b branch         pyOptSparse git branch. Default: v1.2
    -h                Display usage and exit.
    -l linear_solver  One of mumps, hsl, or pardiso. Default: mumps
    -n                Prepare, but do NOT build/install pyOptSparse.
                        Default: build & install
    -p prefix         Where to install. Default: $HOME/ipopt
                      Note: If older versions are already installed in
                      this dir, the build may fail. If it does, rename
                      the directory or removing the old versions.
    -s snopt_dir      Include SNOPT from snopt_dir. Default: no SNOPT
    -a                Include ParOpt. Default: no ParOpt

NOTES:
    If HSL is selected as the linear solver, the
    coinhsl-archive-${HSL_VER}.tar.gz file must exist in the current
    directory. This can be obtained from http://www.hsl.rl.ac.uk/ipopt/

    If PARDISO is selected as the linear solver, the Intel compiler suite
    with MKL must be available.
    
    Examples:
      $0
      $0 -l pardiso
      $0 -l hsl -n
USAGE
    exit 3
}

while getopts ":b:hl:np:s:a" opt; do
    case ${opt} in
        b)
            PYOPTSPARSE_BRANCH="$OPTARG" ;;
        h)
            usage ;;
        l)
            case ${OPTARG^^} in
                MUMPS|HSL)
                    LINEAR_SOLVER=${OPTARG^^}
                    COMPILER_SUITE=GNU ;;
                PARDISO)
                    LINEAR_SOLVER=${OPTARG^^}
                    COMPILER_SUITE=Intel ;;
                *)
                    echo "Unrecognized linear solver specified."
                    usage ;;
            esac
            ;;
        n)
            BUILD_PYOPTSPARSE=0 ;;
        p)
            PREFIX="$OPTARG" ;;
        s)
            INCLUDE_SNOPT=1
            SNOPT_DIR="$OPTARG"
            set -x
            echo "ls SNOPT"
            ls -l
            ls -l SNOPT

            if [ ! -d "$SNOPT_DIR" ]; then
                set -x
                echo "ls SNOPT"
                ls -l SNOPT

                echo "Specified SNOPT source dir $SNOPT_DIR doesn't exist."
                exit 1
            fi
            ;;
        a)
            INCLUDE_PAROPT=1 ;;
        \?)
            echo "Unrecognized option -${OPTARG} specified."
            usage ;;
        :)
            echo "Option -${OPTARG} requires an argument."
            usage ;;
    esac
done

# Choose compiler and make settings:
case $COMPILER_SUITE in
    GNU)
        CC=gcc
        CXX=g++
        FC=gfortran
        ;;
    Intel)
        CC=icc
        CXX=icpc
        FC=ifort
        ;;
    *)
        echo "Unknown compiler suite specified."
        exit 2
        ;;
esac

MAKEFLAGS='-j 6'
export CC CXX FC MAKEFLAGS

REQUIRED_CMDS="make $CC $CXX $FC sed git curl tar"
if [ $BUILD_PYOPTSPARSE = 1 ]; then
    REQUIRED_CMDS="$REQUIRED_CMDS python pip swig"
fi

####################################################################

set -e
trap 'cmd_failed $? $LINENO' EXIT

cmd_failed() {
	if [ "$1" != "0" ]; then
		echo "FATAL ERROR: The command failed with error $1 at line $2."
		exit 1
	fi
}

missing_cmds=''
for c in $REQUIRED_CMDS; do
	type -p $c > /dev/null || missing_cmds="$missing_cmds $c"
done

[ -z "$missing_cmds" ] || {
	echo "Missing required commands:$missing_cmds"
	exit 1
}

# TODO: Pre-check for more deps: lapack, blas, numpy

bkp_dir() {
    check_dir=$1
    if [ -d "$check_dir" ]; then
        echo "Renaming $check_dir to ${check_dir}.bkp.${BUILD_TIME}"
        mv "$check_dir" "${check_dir}.bkp.${BUILD_TIME}"
    fi
}

install_metis() {
    bkp_dir ThirdParty-Metis

    # Install METIS
    git clone https://github.com/coin-or-tools/ThirdParty-Metis.git
    pushd ThirdParty-Metis
    ./get.Metis
    ./configure --prefix=$PREFIX
    make
    make install
    popd
}

install_ipopt() {
    bkp_dir Ipopt

    echo $CC $CXX $FC
    if [ $IPOPT_VER = 'MASTER' ]; then
        git clone https://github.com/coin-or/Ipopt.git
    else
        ipopt_file=Ipopt-${IPOPT_VER}.tgz
        curl -O https://www.coin-or.org/download/source/Ipopt/$ipopt_file
        tar xf $ipopt_file
        rm $ipopt_file
        mv Ipopt-*${IPOPT_VER}* Ipopt
    fi

    pushd Ipopt
    ./configure --prefix=${PREFIX} --disable-java "$@"
    make
    make install
    popd
}

install_paropt() {
    bkp_dir paropt
    echo ">>> Installing gxx_linux-64 and gfortran_linux-64";
    conda install -v -c conda-forge gxx_linux-64 --yes;
    conda install -v -c conda-forge gfortran_linux-64 --yes;
    echo ">>> Done installing gxx_linux-64 and gfortran_linux-64";

    git clone https://github.com/gjkennedy/paropt
    pushd paropt
    cp Makefile.in.info Makefile.in
    make PAROPT_DIR=$PWD
    # CFLAGS='-stdlib=libc++' python setup.py install
    python setup.py install
    popd
 }

build_pyoptsparse() {
    patch_type=$1

    bkp_dir pyoptsparse
    git clone -b "$PYOPTSPARSE_BRANCH" https://github.com/mdolab/pyoptsparse.git

    if [ "$PYOPTSPARSE_BRANCH" = "v1.2" ]; then
        case $patch_type in
            mumps)
                sed -i -e "s/coinhsl/coinmumps', 'coinmetis/" pyoptsparse/pyoptsparse/pyIPOPT/setup.py
                ;;
            pardiso)
                sed -i -e "s/'coinhsl', //;s/, 'blas', 'lapack'//" pyoptsparse/pyoptsparse/pyIPOPT/setup.py
                ;;
        esac
    elif [ "$PYOPTSPARSE_BRANCH" = "v2.1.3" ]; then
        case $patch_type in
            mumps)
                sed -i -e 's/coinhsl/coinmumps", "coinmetis/' pyoptsparse/pyoptsparse/pyIPOPT/setup.py
                ;;
            pardiso)
                sed -i -e 's/"coinhsl", //;s/, "blas", "lapack"//' pyoptsparse/pyoptsparse/pyIPOPT/setup.py
                ;;
        esac
    fi

    if [ $INCLUDE_SNOPT = 1 ]; then
        rsync -a --exclude snopth.f "${SNOPT_DIR}/" ./pyoptsparse/pyoptsparse/pySNOPT/source/
    fi

    if [ "$PYOPTSPARSE_BRANCH" = "v2.1.3" ] && [ $INCLUDE_PAROPT = 1 ] ; then
    echo ">>> Installing paropt";
      install_paropt
    fi

    if [ $BUILD_PYOPTSPARSE = 1 ]; then
        python -m pip install sqlitedict

        # Necessary for pyoptsparse to find IPOPT:
        export IPOPT_INC=$PREFIX/include/coin-or
        export IPOPT_LIB=$PREFIX/lib
        python -m pip install --no-cache-dir ./pyoptsparse
    else
	echo -----------------------------------------------------
	echo NOT building pyOptSparse by request. Make sure to set
	echo these variables before building it yourself:
	echo
	echo export IPOPT_INC=$PREFIX/include/coin-or
	echo export IPOPT_LIB=$PREFIX/lib
	echo -----------------------------------------------------
    fi
}

install_with_mumps() {
    install_metis
    bkp_dir ThirdParty-Mumps

    # Install MUMPS
    git clone https://github.com/coin-or-tools/ThirdParty-Mumps.git
    pushd ThirdParty-Mumps
    ./get.Mumps
    ./configure --with-metis --with-metis-lflags="-L${PREFIX}/lib -lcoinmetis" \
       --with-metis-cflags="-I${PREFIX}/include -I${PREFIX}/include/coin-or -I${PREFIX}/include/coin-or/metis" \
       --prefix=$PREFIX CFLAGS="-I${PREFIX}/include -I${PREFIX}/include/coin-or -I${PREFIX}/include/coin-or/metis" \
       FCFLAGS="-I${PREFIX}/include -I${PREFIX}/include/coin-or -I${PREFIX}/include/coin-or/metis"
    make
    make install
    popd

    install_ipopt --with-mumps --with-mumps-lflags="-L${PREFIX}/lib -lcoinmumps" \
        --with-mumps-cflags="-I${PREFIX}/include/coin-or/mumps"

    # Build and install pyoptsparse
    build_pyoptsparse mumps
}

install_with_hsl() {
    install_metis
    bkp_dir ThirdParty-HSL

    # Unpack, build, and install HSL archive lib:
    hsl_top=coinhsl-archive-${HSL_VER}
    hsl_tar_file=../${hsl_top}.tar.gz
    git clone https://github.com/coin-or-tools/ThirdParty-HSL
    pushd ThirdParty-HSL
    tar xf $hsl_tar_file
    mv $hsl_top coinhsl
    ./configure --prefix=$PREFIX --with-metis \
       --with-metis-lflags="-L${PREFIX}/lib -lcoinmetis" \
       --with-metis-cflags="-I${PREFIX}/include"
    make
    make install
    popd

    install_ipopt --with-hsl --with-hsl-lflags="-L${PREFIX}/lib -lcoinhsl -lcoinmetis" \
        --with-hsl-cflags="-I${PREFIX}/include/coin-or/hsl" --disable-linear-solver-loader

    build_pyoptsparse hsl
}

install_with_pardiso() {
    install_ipopt --with-lapack="-mkl"

    # pyOptSparse doesn't do well with Intel compilers, so unset:
    unset CC CXX FC
    build_pyoptsparse pardiso
}

case $LINEAR_SOLVER in
    MUMPS)
        install_with_mumps ;;
    HSL)
        install_with_hsl ;;
    PARDISO)
        install_with_pardiso ;;
    *)
        echo "Unknown linear solver specified."
        exit 2
        ;;
esac

echo Done.
exit 0
