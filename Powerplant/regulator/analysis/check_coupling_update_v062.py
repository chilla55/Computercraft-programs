"""Compile the actual upstream TransformerCoupling against a recording matrix.

Usage: python3 check_coupling_update_v062.py /path/to/PowerGrid
Requires javac/java. No Minecraft execution, server changes, or network access.
Stubs record additive matrix writes only; this does not reproduce an explosion.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]) / 'src/main/java/org/patryk3211/powergrid/electricity/sim/node/TransformerCoupling.java'
package = 'org/patryk3211/powergrid/electricity/sim/'
files = {
    package + 'ElectricalNetwork.java': '''package org.patryk3211.powergrid.electricity.sim;
public class ElectricalNetwork {
 public static final double G_MIN=1e-12;
 public static final Log LOGGER=null;
 public static class Log { public void warn(String text) {} }
 public double diagonal;
 public void alterConductanceMatrix(int row,int col,double change) {
  if(row==4 && col==4) diagonal+=change;
 }
}''',
    package + 'solver/IAdmittanceAdder.java': '''package org.patryk3211.powergrid.electricity.sim.solver;
public interface IAdmittanceAdder { void add(int row,int col,double value); }''',
    package + 'node/IElectricNode.java': '''package org.patryk3211.powergrid.electricity.sim.node;
public interface IElectricNode { int getIndex(); }''',
    package + 'node/CouplingNode.java': '''package org.patryk3211.powergrid.electricity.sim.node;
import java.util.Collection;
import org.patryk3211.powergrid.electricity.sim.ElectricalNetwork;
import org.patryk3211.powergrid.electricity.sim.solver.IAdmittanceAdder;
public abstract class CouplingNode {
 public ElectricalNetwork network; protected int index=4;
 public abstract void couple(IAdmittanceAdder adder);
 public abstract Collection<IElectricNode> coupledNodes();
}''',
    'Check.java': '''import org.patryk3211.powergrid.electricity.sim.ElectricalNetwork;
import org.patryk3211.powergrid.electricity.sim.node.*;
public class Check {
 static double stamp(TransformerCoupling c) {
  double[] value={0};
  c.couple((row,col,v)->{ if(row==4 && col==4) value[0]+=v; });
  return value[0];
 }
 public static void main(String[] args) {
  IElectricNode p=()->0, common=()->1, tap=()->2;
  // Same four-terminal factory overload used by a variac: shared common.
  TransformerCoupling c=TransformerCoupling.create(.9f,.06f,p,common,tap,common);
  c.network=new ElectricalNetwork(); c.network.diagonal=stamp(c);
  c.setResistance(.08f);
  double incremental=c.network.diagonal, rebuilt=stamp(c);
  System.out.printf("four-terminal incremental=%.8f rebuilt=%.8f mismatch=%.8f%n",
                    incremental,rebuilt,incremental-rebuilt);
  if(Math.abs(incremental-rebuilt)<1e-7) throw new AssertionError("Expected v0.6.2 discrepancy absent");
  c.setResistance(.13f);
  System.out.printf("after larger increase: incremental=%.8f rebuilt=%.8f (sign reversal)%n",
                    c.network.diagonal,stamp(c));
  if(c.network.diagonal<=0 || stamp(c)>=0) throw new AssertionError("Sign reversal not reproduced");
  // Control: the base setter agrees with the two-terminal positive stamp.
  TransformerCoupling control=TransformerCoupling.create(.9f,.06f,p,tap);
  control.network=new ElectricalNetwork(); control.network.diagonal=stamp(control);
  control.setResistance(.08f);
  if(Math.abs(control.network.diagonal-stamp(control))>1e-7) throw new AssertionError("Control mismatch");
  System.out.println("Confirmed source-level update/stamp inconsistency; NOT an in-game failure reproduction.");
 }
}'''
}
with tempfile.TemporaryDirectory(prefix='pg-coupling-') as folder:
    root = pathlib.Path(folder)
    for name, content in files.items():
        p = root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
    shutil.copyfile(source, root / package / 'node/TransformerCoupling.java')
    subprocess.run(['javac', '-d', str(root / 'classes'), *map(str, root.rglob('*.java'))], check=True)
    subprocess.run(['java', '-cp', str(root / 'classes'), 'Check'], check=True)
