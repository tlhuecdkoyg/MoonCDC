///|
/// SQL-only decomposition works in persistent triggers on external connections.
/// Eleven scaling stages cover the finite binary64 exponent range. All factors
/// are built from 2.0 by exact squaring, avoiding decimal REAL constants too.
fn sqlite_real_wire(expression : String) -> String {
  let scale = "CASE WHEN abs(m)>=4503599627370496.0*f THEN m/f" +
    " WHEN m<>0 AND abs(m)<9007199254740992.0/f THEN m*f ELSE m END"
  let step = "CASE WHEN abs(m)>=4503599627370496.0*f THEN k" +
    " WHEN m<>0 AND abs(m)<9007199254740992.0/f THEN -k ELSE 0 END"
  "(WITH RECURSIVE mooncdc_powers(k,f) AS (VALUES(1,2.0)" +
  " UNION ALL SELECT k*2,f*f FROM mooncdc_powers WHERE k<512)," +
  " mooncdc_stages(i,k) AS (VALUES(0,512),(1,512),(2,256),(3,128),(4,64),(5,32),(6,16),(7,8),(8,4),(9,2),(10,1))," +
  " mooncdc_real(i,m,e) AS (SELECT 0," +
  expression +
  ",0 UNION ALL SELECT i+1," +
  scale +
  ",e+(" +
  step +
  ") FROM mooncdc_real JOIN mooncdc_stages USING(i) JOIN mooncdc_powers USING(k))" +
  " SELECT CASE WHEN abs(m)>1.7976931348623157e308 THEN json_array('real','nonfinite')" +
  " WHEN m=0 THEN json_array('real','0','0')" +
  " ELSE json_array('real',CAST(CAST(m AS INTEGER) AS TEXT),CAST(e AS TEXT)) END" +
  " FROM mooncdc_real WHERE i=11)"
}
