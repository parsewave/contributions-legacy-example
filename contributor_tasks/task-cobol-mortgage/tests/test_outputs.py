import subprocess
import os
from pathlib import Path


def test_required_files_exist():
    """Test that all required COBOL files exist"""
    required_files = [
        "/app/src/program.cbl",
    ]

    for file_path in required_files:
        assert Path(file_path).exists(), f"Required file program.cbl {file_path} does not exist"

def test_fixed_format_constraints():
    """Test that the code is written in fixed format"""
    src = Path("/app/src/program.cbl").read_text()
    assert ">>SOURCE FORMAT IS FIXED" not in src
    longest = max(len(line.rstrip("\n")) for line in src.splitlines())
    assert longest <= 80

def test_data_files_exist():
    """Test that all required data files exist"""
    data_files = [
        "/app/src/INPUT.DAT",
    ]

    for file_path in data_files:
        assert Path(file_path).exists(), f"Data file {file_path} does not exist"

def test_program_output():
    """Test that the program produces the expected output and file contents"""
    initial_OUTPUT = ""

    data_dir = Path("/app/data")

    (data_dir / "OUTPUT.DAT").write_text(initial_OUTPUT)

    Path("/app/src/INPUT.DAT").write_text(
"""APP0000001;Williams David Robert         ;2000000000;3500000000;0500000000;20;00550
APP0000002;John Smith Clark              ;0000005000;0000004000;0000003500;01;00550""")

    # Compile the COBOL program
    compile_result = subprocess.run([
        'cobc', 
        '-x', 
        '-o', 
        '/app/src/programCOMP', 
        '/app/src/program.cbl'
    ], capture_output=True, text=True)
    
    assert compile_result.returncode == 0, f"Compilation failed: {compile_result.stderr}"
    
    # Run the compiled program
    result = subprocess.run(
        ['/app/src/programCOMP'], 
        capture_output=True, 
        text=True
    )

    assert result.returncode == 0, f"Program failed: {result.stderr}"

    expected_OUTPUT = (
"""APP0000001DENY INSUFFICIENT FUNDS FOR DOWN PAYMENT
APP0000002APPRO
001 00000429.18 00000022.92 00000406.26 0000004593.74
002 00000429.18 00000021.05 00000408.13 0000004185.61
003 00000429.18 00000019.18 00000410.00 0000003775.61
004 00000429.18 00000017.30 00000411.88 0000003363.73
005 00000429.18 00000015.42 00000413.76 0000002949.97
006 00000429.18 00000013.52 00000415.66 0000002534.31
007 00000429.18 00000011.61 00000417.57 0000002116.74
008 00000429.18 00000009.70 00000419.48 0000001697.26
009 00000429.18 00000007.78 00000421.40 0000001275.86
010 00000429.18 00000005.85 00000423.33 0000000852.53
011 00000429.18 00000003.91 00000425.27 0000000427.26
012 00000429.22 00000001.96 00000427.26 0000000000.00\n"""
    )

    assert (data_dir / "OUTPUT.DAT").read_text() == expected_OUTPUT, (
        "OUTPUT.DAT content mismatch"
    )
